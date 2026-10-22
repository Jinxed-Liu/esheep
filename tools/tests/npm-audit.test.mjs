import assert from 'node:assert/strict';
import test from 'node:test';
import { audit } from '../npm-audit.mjs';

const clean = { status: 0, stdout: '{"metadata":{"vulnerabilities":{"total":0}}}' };
const timeout = { status: 1, stdout: '{"error":{"code":"ETIMEDOUT"}}' };

async function simulate(results, args = []) {
    let calls = 0;
    const delays = [];
    const code = await audit({ args, run: (command, actualArgs) => {
        assert.equal(command, 'npm');
        assert.ok(actualArgs.includes('--fetch-timeout=20000'));
        for (const arg of args) assert.ok(actualArgs.includes(arg));
        return results[calls++];
    }, wait: async ms => delays.push(ms), output: () => {} });
    return { code, calls, delays };
}

test('clean audit succeeds once and preserves caller severity options', async () => {
    assert.deepEqual(await simulate([clean], ['--omit=dev', '--audit-level=high']), { code: 0, calls: 1, delays: [] });
});
test('temporary network failure retries and requires a successful audit', async () => {
    assert.deepEqual(await simulate([timeout, clean]), { code: 0, calls: 2, delays: [2000] });
});
test('exhausted network retries remain a failure', async () => {
    assert.deepEqual(await simulate([timeout, timeout, timeout]), { code: 1, calls: 3, delays: [2000, 4000] });
});
test('vulnerabilities fail immediately without retry', async () => {
    const findings = { status: 1, stdout: '{"metadata":{"vulnerabilities":{"total":2}},"vulnerabilities":{"vitest":{}}}' };
    assert.deepEqual(await simulate([findings, clean]), { code: 1, calls: 1, delays: [] });
});
test('invalid responses and permanent errors fail closed', async () => {
    for (const response of [{ status: 1, stdout: 'not JSON' }, { status: 1, stdout: '{"error":{"code":"E401"}}' }]) {
        assert.deepEqual(await simulate([response, clean]), { code: 1, calls: 1, delays: [] });
    }
});
test('process timeout also has a bounded retry', async () => {
    assert.deepEqual(await simulate([{ status: null, error: { code: 'ETIMEDOUT' } }, clean]), { code: 0, calls: 2, delays: [2000] });
});
