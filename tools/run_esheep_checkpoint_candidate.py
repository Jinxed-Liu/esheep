#!/usr/bin/env python3
"""Protected CI entrypoint. Preflight is offline; candidate execution is gated.

Business output and tracebacks are private. Public output contains only fixed
stage names, status words and numeric exit codes. This never publishes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import traceback
import uuid

from checkpoint_source_cli import check_cli

ROOT = Path(__file__).resolve().parents[1]
APPROVAL_FILES = ('semantic-reconciliation.json', 'post-repair-field-audit.json',
                  'commands.json', 'expected-sheep.json', 'expected-business.json')
REPORTS = ('independent-reconciliation', 'approved-history-reconciliation',
           'purpose-history-reconciliation')


def configuration(env):
    value = json.loads(env['ESHEEP_CHECKPOINT_WORKER_CONFIG'])
    fields = ('project', 'farm', 'destination', 'approved_source', 'approved_sha256', 'evidence_root')
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError('Invalid worker configuration fields')
    if not all(isinstance(value[k], str) and value[k].strip() for k in fields):
        raise ValueError('Empty worker configuration')
    if not re.fullmatch(r'[a-z]{20}', value['project']):
        raise ValueError('Invalid project')
    uuid.UUID(value['farm'])
    if not re.fullmatch(r'[a-f0-9]{64}', value['approved_sha256']):
        raise ValueError('Approval hash must be pinned')
    match = re.fullmatch(r'platform=iOS Simulator,id=([A-Fa-f0-9-]{36})', value['destination'])
    if not match:
        raise ValueError('An explicit simulator UUID is required')
    uuid.UUID(match[1])
    if not all(Path(value[k]).is_absolute() for k in ('approved_source', 'evidence_root')):
        raise ValueError('Worker paths must be absolute')
    return value


def run_directory(config, env):
    root = Path(config['evidence_root'])
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Private evidence root must already exist')
    root = root.resolve()
    info = root.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o777 != 0o700:
        raise ValueError('Evidence root must be owned by the worker and private')
    forbidden = [ROOT]
    for name in ('RUNNER_TEMP', 'GITHUB_WORKSPACE', 'RUNNER_WORKSPACE'):
        if env.get(name):
            forbidden.append(Path(env[name]).resolve())
    if any(root == path or path in root.parents for path in forbidden):
        raise ValueError('Evidence must be outside checkout and runner temporary/work directories')
    for name in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT'):
        if not re.fullmatch(r'[1-9][0-9]*', env.get(name, '')):
            raise ValueError('Invalid run identity')
    return root / ('esheep-checkpoint-' + env['GITHUB_RUN_ID'] + '-' + env['GITHUB_RUN_ATTEMPT'])


def approved_inputs(config):
    """Read once, validate the pinned proof and all four referenced inputs."""
    root = Path(config['approved_source'])
    blobs = {}
    for name in APPROVAL_FILES:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Incomplete approval evidence')
        blobs[name] = path.read_bytes()
    if hashlib.sha256(blobs[APPROVAL_FILES[0]]).hexdigest() != config['approved_sha256']:
        raise ValueError('Approval proof hash mismatch')
    proof = json.loads(blobs[APPROVAL_FILES[0]])
    if proof.get('passed') is not True or proof.get('tableCount') != 46:
        raise ValueError('Approval proof did not pass')
    hashes = proof['sourceHashes']
    if not isinstance(hashes, dict):
        raise ValueError('Approval hashes missing')
    for name in APPROVAL_FILES[1:]:
        matches = [digest for path, digest in hashes.items() if Path(path).name == name]
        if matches != [hashlib.sha256(blobs[name]).hexdigest()]:
            raise ValueError('Approval input hash missing, duplicated or changed')
    commands = json.loads(blobs['commands.json'])
    if not isinstance(commands, list) or not commands:
        raise ValueError('Approval command set is empty')
    farm = uuid.UUID(config['farm'])
    generations, identifiers = set(), set()
    for command in commands:
        if uuid.UUID(command['farmID']) != farm or type(command['farmGeneration']) is not int:
            raise ValueError('Approval farm identity mismatch')
        generations.add(command['farmGeneration'])
        identifiers.add(uuid.UUID(command['commandID']))
    if len(generations) != 1 or min(generations) < 1 or len(identifiers) != len(commands):
        raise ValueError('Approval generation or command identity mismatch')
    for name in ('expected-sheep.json', 'expected-business.json'):
        if not isinstance(json.loads(blobs[name]), list):
            raise ValueError('Invalid approved facts')
    audit = json.loads(blobs['post-repair-field-audit.json'])
    if not isinstance(audit.get('tables'), list) or not isinstance(audit.get('differences'), list):
        raise ValueError('Invalid approved audit')
    return blobs


def probe(args):
    return subprocess.run(args, capture_output=True, text=True, check=True,
                          timeout=60, stdin=subprocess.DEVNULL).stdout


def check_tools(config):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('Apple silicon macOS worker required')
    probe(['xcodebuild', '-version'])
    probe(['xcodebuild', '-checkFirstLaunchStatus'])
    swift = re.search(r'Swift version (\d+)\.(\d+)', probe(['xcrun', 'swift', '--version']))
    if not swift or tuple(map(int, swift.groups())) < (6, 2):
        raise RuntimeError('Swift 6.2 or later required')
    identifier = config['destination'].split('id=', 1)[1].lower()
    devices = json.loads(probe(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    if not any(device.get('isAvailable') is True and device.get('udid', '').lower() == identifier
               for runtime, group in devices['devices'].items() if '.iOS-' in runtime
               for device in group):
        raise RuntimeError('Configured iOS simulator is unavailable')
    probe(['git', '--version'])
    if not (ROOT/'Packages/ESMotion/Package.swift').is_file():
        raise RuntimeError('Repository-local ESMotion is missing')
    check_cli()


def candidate_command(config, work, event):
    args = [sys.executable, str(ROOT/'tools/build_esheep_cloud_checkpoint.py'),
            '--project', config['project'], '--farm', config['farm'],
            '--destination', config['destination'], '--output', str(work/'build'),
            '--approved-source', str(work/'approved-source')]
    if event == 'schedule':
        args.append('--only-if-due')
    return args


def execute(env, preflight_only=False):
    prior_umask = os.umask(0o077)
    stage, work, log = 'configuration', None, None
    try:
        config = configuration(env)
        work = run_directory(config, env)
        if not preflight_only:
            work.mkdir(mode=0o700, exist_ok=False)
            log = (work/'worker.log').open('x')
        stage = 'credentials'
        if not env.get('SUPABASE_ACCESS_TOKEN', '').strip():
            raise ValueError('Explicit source token required')
        stage = 'approval'
        blobs = approved_inputs(config)
        stage = 'tools'
        check_tools(config)
        if preflight_only:
            print('checkpoint preflight: passed; production access: none')
            return 0
        stage = 'trigger'
        if env.get('GITHUB_EVENT_NAME') not in ('schedule', 'workflow_dispatch'):
            raise ValueError('Unsupported trigger')
        if env.get('GITHUB_REF') != 'refs/heads/main':
            raise ValueError('Only reviewed main jobs are allowed')
        stage = 'approval-snapshot'
        approved = work/'approved-source'
        approved.mkdir(mode=0o700)
        for name, data in blobs.items():
            with (approved/name).open('xb') as output:
                output.write(data)
        print('checkpoint preflight: passed', flush=True)
        stage = 'candidate'
        subprocess.run(candidate_command(config, work, env['GITHUB_EVENT_NAME']),
                       cwd=ROOT, env=dict(env), stdout=log, stderr=subprocess.STDOUT,
                       stdin=subprocess.DEVNULL, check=True)
        status = 'not-due' if (work/'build/not-due.json').is_file() else 'verified'
        # Do not trust a successful child that omitted one of the release gates.
        if status == 'verified':
            for name in REPORTS:
                if json.loads((work/'build/candidate'/(name+'.json')).read_bytes()).get('passed') is not True:
                    raise ValueError('Candidate reconciliation did not pass')
        (work/'outcome.json').write_text(json.dumps({'status': status}))
        log.flush()
        print('checkpoint candidate: ' + status)
        return 0
    except Exception as error:
        if log is not None:
            try:
                traceback.print_exc(file=log)
                (work/'outcome.json').write_text(json.dumps({'status': 'failed', 'stage': stage}))
            except Exception:
                # A full/unwritable disk must not expose a fallback traceback.
                pass
        code = error.returncode if isinstance(error, subprocess.CalledProcessError) else 1
        # Never interpolate exception text, argv, config values or business data.
        print(f'checkpoint {stage}: failed; exit_code={code}', file=sys.stderr)
        return 1
    finally:
        if log is not None:
            try:
                log.close()
            except Exception:
                pass
        os.umask(prior_umask)


def summary(env):
    work = None
    try:
        work = run_directory(configuration(env), env)
    except Exception:
        pass
    outcome = env.get('CHECKPOINT_STEP_OUTCOME', '')
    outcome = outcome if outcome in ('success', 'failure', 'cancelled', 'skipped') else 'unknown'
    lines = ['Candidate step: ' + outcome]
    if work:
        try:
            status = json.loads((work/'outcome.json').read_bytes()).get('status')
            if status in ('verified', 'not-due', 'failed'):
                lines.append('Candidate result: ' + status)
        except Exception:
            pass
    for name in REPORTS:
        status = 'not produced'
        try:
            path = work/'build/candidate'/(name+'.json') if work else None
            if path and path.is_file():
                status = 'passed' if json.loads(path.read_bytes()).get('passed') is True else 'failed'
        except Exception:
            status = 'invalid report'
        lines.append(name + ': ' + status)
    lines.append('Detailed evidence, when produced, remains in the private persistent worker directory; no business artifacts are uploaded.')
    text = '\n\n'.join(lines) + '\n'
    if env.get('GITHUB_STEP_SUMMARY'):
        with open(env['GITHUB_STEP_SUMMARY'], 'a') as output:
            output.write(text)
    else:
        print(text, end='')
    return 0


def main(argv=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--preflight-only', action='store_true', help='No database access or candidate execution')
    mode.add_argument('--summary-only', action='store_true', help='Render only allowlisted report statuses')
    args = parser.parse_args(argv)
    if args.summary_only:
        try:
            return summary(os.environ)
        except Exception:
            print('checkpoint summary: failed', file=sys.stderr)
            return 1
    return execute(os.environ, args.preflight_only)


if __name__ == '__main__':
    sys.exit(main())
