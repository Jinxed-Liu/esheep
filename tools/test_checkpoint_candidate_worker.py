"""Offline tests with synthetic evidence and intercepted process execution.

No database, Runner registration, simulator boot or real business input.
"""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import build_esheep_cloud_checkpoint as builder
import checkpoint_source_cli as cli
import run_esheep_checkpoint_candidate as worker


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.evidence = self.root/'evidence'
        self.evidence.mkdir(mode=0o700)
        self.approved = self.root/'approved'
        self.approved.mkdir(mode=0o700)
        self.config = dict(project='a'*20, farm='11111111-2222-4333-8444-555555555555',
            destination='platform=iOS Simulator,id=11111111-2222-4333-8444-666666666666',
            approved_source=str(self.approved), evidence_root=str(self.evidence))
        inputs = {
            'commands.json': [dict(farmID=self.config['farm'], farmGeneration=1,
                                  commandID='11111111-2222-4333-8444-777777777777')],
            'expected-sheep.json': [], 'expected-business.json': [],
            'post-repair-field-audit.json': dict(tables=[], differences=[]),
        }
        for name, value in inputs.items():
            (self.approved/name).write_text(json.dumps(value))
        self.reseal()
        self.env = dict(ESHEEP_CHECKPOINT_WORKER_CONFIG=json.dumps(self.config),
            SUPABASE_ACCESS_TOKEN='synthetic-test-token', GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='1',
            GITHUB_EVENT_NAME='workflow_dispatch', GITHUB_REF='refs/heads/main',
            GITHUB_WORKSPACE=str(self.root/'checkout'), RUNNER_TEMP=str(self.root/'runner-temp'),
            RUNNER_WORKSPACE=str(self.root/'runner-workspace'))
        self.stdout, self.stderr = io.StringIO(), io.StringIO()

    def reseal(self):
        hashes = {str(Path('/old-approved-location')/name): hashlib.sha256((self.approved/name).read_bytes()).hexdigest()
                  for name in worker.APPROVAL_FILES[1:]}
        proof = json.dumps(dict(passed=True, tableCount=46, sourceHashes=hashes)).encode()
        (self.approved/'semantic-reconciliation.json').write_bytes(proof)
        self.config['approved_sha256'] = hashlib.sha256(proof).hexdigest()

    def update_config(self):
        self.env['ESHEEP_CHECKPOINT_WORKER_CONFIG'] = json.dumps(self.config)

    def execute(self, **kwargs):
        with contextlib.redirect_stdout(self.stdout), contextlib.redirect_stderr(self.stderr):
            return worker.execute(self.env, **kwargs)

    @property
    def run_root(self):
        return self.evidence/'esheep-checkpoint-123-1'

    @staticmethod
    def successful_child(args, **kwargs):
        output = Path(args[args.index('--output')+1])
        reports = output/'candidate'
        reports.mkdir(parents=True)
        for name in worker.REPORTS:
            (reports/(name+'.json')).write_text(json.dumps(dict(passed=True, private='private-business-marker')))
        return subprocess.CompletedProcess(args, 0)

    def test_missing_token_blocks_before_tool_or_query(self):
        self.env['SUPABASE_ACCESS_TOKEN'] = ''
        with mock.patch.object(worker, 'check_tools') as tools, mock.patch.object(subprocess, 'run') as run:
            self.assertEqual(self.execute(), 1)
        tools.assert_not_called(); run.assert_not_called()
        self.assertIn('credentials: failed', self.stderr.getvalue())

    def test_incomplete_approval_blocks_before_tool_or_query(self):
        (self.approved/'commands.json').unlink()
        with mock.patch.object(worker, 'check_tools') as tools, mock.patch.object(subprocess, 'run') as run:
            self.assertEqual(self.execute(), 1)
        tools.assert_not_called(); run.assert_not_called()
        self.assertIn('approval: failed', self.stderr.getvalue())

    def test_changed_proof_or_input_is_rejected(self):
        for name in worker.APPROVAL_FILES:
            with self.subTest(name=name):
                path = self.approved/name; original = path.read_bytes()
                path.write_bytes(original+b' ')
                with self.assertRaises(ValueError): worker.approved_inputs(self.config)
                path.write_bytes(original)

    def test_missing_hash_in_pinned_proof_is_rejected(self):
        proof = json.loads((self.approved/'semantic-reconciliation.json').read_bytes())
        proof['sourceHashes'].pop('/old-approved-location/expected-sheep.json')
        raw = json.dumps(proof).encode(); (self.approved/'semantic-reconciliation.json').write_bytes(raw)
        self.config['approved_sha256'] = hashlib.sha256(raw).hexdigest()
        with self.assertRaises(ValueError): worker.approved_inputs(self.config)

    def test_approval_cannot_belong_to_another_farm(self):
        self.config['farm'] = '22222222-2222-4333-8444-555555555555'
        with self.assertRaises(ValueError): worker.approved_inputs(self.config)

    def test_root_must_be_private_and_outside_runner_scratch(self):
        self.evidence.chmod(0o755)
        with self.assertRaises(ValueError): worker.run_directory(self.config, self.env)
        self.evidence.chmod(0o700)
        for name in ('GITHUB_WORKSPACE', 'RUNNER_TEMP', 'RUNNER_WORKSPACE'):
            with self.subTest(name=name):
                env = dict(self.env, **{name: str(self.root)})
                with self.assertRaises(ValueError): worker.run_directory(self.config, env)

    def test_root_symlink_is_rejected(self):
        link = self.root/'evidence-link'; link.symlink_to(self.evidence, target_is_directory=True)
        self.config['evidence_root'] = str(link)
        with self.assertRaises(ValueError): worker.run_directory(self.config, self.env)

    def test_existing_run_is_never_overwritten(self):
        self.run_root.mkdir(); (self.run_root/'keep').write_text('keep')
        with mock.patch.object(subprocess, 'run') as run:
            self.assertEqual(self.execute(), 1)
        run.assert_not_called()
        self.assertEqual((self.run_root/'keep').read_text(), 'keep')

    def test_preflight_only_never_creates_candidate_or_starts_child(self):
        with mock.patch.object(worker, 'check_tools') as tools, mock.patch.object(subprocess, 'run') as run:
            self.assertEqual(self.execute(preflight_only=True), 0)
        tools.assert_called_once(); run.assert_not_called()
        self.assertFalse(self.run_root.exists())
        self.assertIn('production access: none', self.stdout.getvalue())

    def test_snapshot_preserves_validated_bytes_and_private_permissions(self):
        original = (self.approved/'expected-sheep.json').read_bytes()
        prior_umask = os.umask(0o022)
        try:
            with mock.patch.object(worker, 'check_tools', side_effect=lambda c: (self.approved/'expected-sheep.json').write_text('["changed"]')):
                with mock.patch.object(subprocess, 'run', side_effect=self.successful_child) as run:
                    self.assertEqual(self.execute(), 0)
        finally:
            os.umask(prior_umask)
        self.assertEqual((self.run_root/'approved-source/expected-sheep.json').read_bytes(), original)
        self.assertEqual(self.run_root.stat().st_mode & 0o777, 0o700)
        for path in self.run_root.rglob('*'):
            if path.is_file(): self.assertEqual(path.stat().st_mode & 0o777, 0o600, path)
        self.assertNotIn('--only-if-due', run.call_args.args[0])
        self.assertNotIn(self.config['farm'], self.stdout.getvalue()+self.stderr.getvalue())

    def test_child_failure_details_stay_private(self):
        marker = 'private-business-marker'
        def fail(args, **kwargs):
            kwargs['stdout'].write(marker+'\n')
            raise subprocess.CalledProcessError(17, args+[marker])
        with mock.patch.object(worker, 'check_tools'), mock.patch.object(subprocess, 'run', side_effect=fail):
            self.assertEqual(self.execute(), 1)
        self.assertIn(marker, (self.run_root/'worker.log').read_text())
        public = self.stdout.getvalue()+self.stderr.getvalue()
        self.assertNotIn(marker, public); self.assertNotIn(self.config['farm'], public)
        self.assertIn('candidate: failed; exit_code=17', public)

    def test_successful_exit_without_all_reports_fails(self):
        with mock.patch.object(worker, 'check_tools'), mock.patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)):
            self.assertEqual(self.execute(), 1)
        self.assertNotIn('candidate: verified', self.stdout.getvalue())

    def test_schedule_not_due_skips_reconciliation_and_is_reported(self):
        self.env['GITHUB_EVENT_NAME'] = 'schedule'
        def skip(args, **kwargs):
            self.assertIn('--only-if-due', args)
            output = Path(args[args.index('--output')+1]); output.mkdir()
            (output/'not-due.json').write_text('{"due":false}')
            return subprocess.CompletedProcess(args, 0)
        with mock.patch.object(worker, 'check_tools'), mock.patch.object(subprocess, 'run', side_effect=skip):
            self.assertEqual(self.execute(), 0)
        with contextlib.redirect_stdout(self.stdout): worker.summary(dict(self.env, CHECKPOINT_STEP_OUTCOME='success'))
        self.assertIn('Candidate result: not-due', self.stdout.getvalue())

    def test_unapproved_branch_never_starts_child(self):
        self.env['GITHUB_REF'] = 'refs/heads/unreviewed'
        with mock.patch.object(worker, 'check_tools'), mock.patch.object(subprocess, 'run') as run:
            self.assertEqual(self.execute(), 1)
        run.assert_not_called()

    def test_summary_contains_only_statuses_even_for_malformed_report(self):
        reports = self.run_root/'build/candidate'; reports.mkdir(parents=True)
        (reports/(worker.REPORTS[0]+'.json')).write_text('{private-business-marker')
        (reports/(worker.REPORTS[1]+'.json')).write_text('{"passed":true,"private":"private-business-marker"}')
        with contextlib.redirect_stdout(self.stdout): worker.summary(self.env)
        value = self.stdout.getvalue()
        self.assertIn('invalid report', value); self.assertIn('passed', value)
        self.assertNotIn('private-business-marker', value)
        self.assertNotIn(self.config['farm'], value)

    def test_unavailable_simulator_fails_before_cli(self):
        def probe(args):
            if args == ['xcrun', 'swift', '--version']: return 'Apple Swift version 6.4.2'
            if 'simctl' in args: return '{"devices":{}}'
            return 'tool version'
        with mock.patch.object(worker.platform, 'system', return_value='Darwin'), mock.patch.object(worker.platform, 'machine', return_value='arm64'):
            with mock.patch.object(worker, 'probe', side_effect=probe), mock.patch.object(worker, 'check_cli') as check:
                with self.assertRaises(RuntimeError): worker.check_tools(self.config)
        check.assert_not_called()


class CLITests(unittest.TestCase):
    def setUp(self):
        cli.check_cli.cache_clear()
        self.addCleanup(cli.check_cli.cache_clear)

    def test_accepts_array_and_agent_envelope_without_losing_integer_precision(self):
        for raw in ('[{"sequence":9223372036854775807}]', '{"rows":[{"sequence":9223372036854775807}],"warning":"untrusted"}'):
            self.assertEqual(cli.parse_rows(raw), [{'sequence': 9223372036854775807}])
        for raw in ('null', '{}', '[1]', '{"rows":"bad"}'):
            with self.assertRaises(ValueError): cli.parse_rows(raw)

    def test_query_is_explicit_remote_readonly_and_noninteractive(self):
        with mock.patch.dict(os.environ, {'SUPABASE_ACCESS_TOKEN':'synthetic'}, clear=True):
            with mock.patch.object(cli, 'check_cli'), mock.patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '[{"due":false}]', '')) as run:
                self.assertEqual(cli.query('a'*20, 'select false as due', '/unused'), [{'due':False}])
        args = run.call_args.args[0]
        self.assertIn('--remote='+'a'*20, args); self.assertIn('--read-only', args)
        self.assertNotIn('--yes', args); self.assertNotIn('--linked', args)
        self.assertEqual(run.call_args.kwargs['stdin'], subprocess.DEVNULL)

    def test_explicit_token_is_required_before_any_process(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(subprocess, 'run') as run:
            with self.assertRaises(RuntimeError): cli.query('a'*20, 'select 1', '/unused')
        run.assert_not_called()

    def test_cli_version_mismatch_blocks_queries(self):
        with mock.patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '2.99.0\n', '')) as run:
            with self.assertRaises(RuntimeError): cli.check_cli()
        self.assertEqual(run.call_count, 1)

    def test_cli_without_readonly_support_is_rejected(self):
        results = [subprocess.CompletedProcess([], 0, cli.SUPABASE_VERSION+'\n', ''),
                   subprocess.CompletedProcess([], 0, '--remote --output', '')]
        with mock.patch.object(subprocess, 'run', side_effect=results):
            with self.assertRaisesRegex(RuntimeError, 'flags_missing'): cli.check_cli()

    def test_query_failure_keeps_sensitive_output_in_private_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'error.log'
            failure = subprocess.CalledProcessError(3, ['supabase'], output='private-row', stderr='private-error')
            with mock.patch.dict(os.environ, {'SUPABASE_ACCESS_TOKEN':'synthetic'}), mock.patch.object(cli, 'check_cli'):
                with mock.patch.object(subprocess, 'run', side_effect=failure):
                    with self.assertRaisesRegex(RuntimeError, '^checkpoint_cli_query_failed$'):
                        cli.query('a'*20, 'select 1', path)
            self.assertIn('private-row', path.read_text()); self.assertIn('private-error', path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_due_false_uses_no_capture_or_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)/'run'
            args = ['worker', '--project', 'a'*20, '--farm', '11111111-2222-4333-8444-555555555555',
                    '--output', str(output), '--destination', 'unused', '--only-if-due']
            with mock.patch.object(sys, 'argv', args), mock.patch.object(builder, 'source_query', return_value=[{'due':False}]), mock.patch.object(subprocess, 'run') as run:
                builder.main()
            run.assert_not_called()
            self.assertFalse(json.loads((output/'not-due.json').read_bytes())['due'])

    def test_invalid_due_value_cannot_silently_skip_work(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = ['worker', '--project', 'a'*20, '--farm', '11111111-2222-4333-8444-555555555555',
                    '--output', str(Path(tmp)/'run'), '--destination', 'unused', '--only-if-due']
            with mock.patch.object(sys, 'argv', args), mock.patch.object(builder, 'source_query', return_value=[{'due':None}]), mock.patch.object(subprocess, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'explicit due boolean'): builder.main()
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
