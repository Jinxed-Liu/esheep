"""Pinned, explicitly read-only CLI transport for the legacy candidate worker.

No login fallback and no automatic CLI installation. Query results and errors
must stay inside the caller's private worker output, never GitHub stdout.
"""
import functools
import json
import os
from pathlib import Path
import re
import subprocess

SUPABASE_VERSION = '3.0.0'


@functools.lru_cache(maxsize=1)
def check_cli():
    result = subprocess.run(['supabase', '--version'], capture_output=True,
                            text=True, check=True, timeout=30)
    if result.stdout.strip() != SUPABASE_VERSION:
        raise RuntimeError('checkpoint_cli_version_mismatch')
    result = subprocess.run(['supabase', 'db', 'query', '--help'],
                            capture_output=True, text=True, check=True, timeout=30)
    if not all(flag in result.stdout for flag in ('--remote', '--read-only', '--output')):
        raise RuntimeError('checkpoint_cli_query_flags_missing')


def parse_rows(raw):
    """v3 emits a row array, or a rows envelope when agent mode is detected."""
    value = json.loads(raw)
    rows = value.get('rows') if isinstance(value, dict) else value
    if not isinstance(rows, list) or not all(isinstance(row, dict) for row in rows):
        raise ValueError('checkpoint_cli_invalid_rows')
    return rows


def query(project, sql, diagnostic_path):
    if not re.fullmatch(r'[a-z]{20}', project):
        raise ValueError('checkpoint_cli_invalid_project')
    if not sql.lstrip().lower().startswith('select '):
        raise ValueError('checkpoint_cli_select_required')
    if not os.environ.get('SUPABASE_ACCESS_TOKEN', '').strip():
        raise RuntimeError('checkpoint_cli_explicit_token_required')
    check_cli()
    # The server-side read-only mode is necessary; a SELECT prefix alone does
    # not prevent a statement/function from making changes.
    args = ['supabase', 'db', 'query', '--remote=' + project, '--read-only',
            sql, '--output', 'json']
    result = None
    try:
        result = subprocess.run(args, capture_output=True, text=True,
                                check=True, timeout=180, stdin=subprocess.DEVNULL)
        return parse_rows(result.stdout)
    except (subprocess.SubprocessError, ValueError) as error:
        # Only the private file receives SQL, returned data or raw CLI errors.
        path = Path(diagnostic_path)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as log:
            os.fchmod(log.fileno(), 0o600)
            log.write(sql + '\n')
            for value in ((result.stdout if result else getattr(error, 'stdout', None)),
                          (result.stderr if result else getattr(error, 'stderr', None))):
                if value:
                    log.write(value.decode(errors='replace') if isinstance(value, bytes) else value)
                    log.write('\n')
            log.write(type(error).__name__ + '\n')
        raise RuntimeError('checkpoint_cli_query_failed') from None
