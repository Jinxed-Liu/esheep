import assert from 'node:assert/strict';
import test from 'node:test';
import { audit } from '../npm-audit.mjs';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

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
test('npm audit errors without a FetchError code retry only known network failures', async () => {
    for (const report of [{ message: 'network timeout at: https://registry.example.invalid/audit', error: {} },
        { statusCode: 503, error: {} }]) {
        assert.deepEqual(await simulate([{ status: 1, stdout: JSON.stringify(report) }, clean]),
            { code: 0, calls: 2, delays: [2000] });
    }
});
test('real npm audit recovers from a controlled local registry timeout', { timeout: 15000 }, async context => {
    const directory = await mkdtemp(join(tmpdir(), 'esheep-audit-'));
    let requests = 0;
    const registry = createServer((request, response) => {
        request.resume();
        if (++requests === 1) return; // First request times out; no external network is used.
        response.writeHead(200, { 'content-type': 'application/json' });
        response.end('{}');
    });
    try {
        await writeFile(join(directory, 'package.json'), JSON.stringify({ name: 'synthetic-audit', version: '1.0.0',
            dependencies: { 'synthetic-dependency': '1.0.0' } }));
        await writeFile(join(directory, 'package-lock.json'), JSON.stringify({ name: 'synthetic-audit', version: '1.0.0',
            lockfileVersion: 3, packages: { '': { name: 'synthetic-audit', version: '1.0.0', dependencies: { 'synthetic-dependency': '1.0.0' } },
                'node_modules/synthetic-dependency': { version: '1.0.0' } } }));
        await new Promise(resolve => registry.listen(0, '127.0.0.1', resolve));
        const child = spawn(process.execPath, [fileURLToPath(new URL('../npm-audit.mjs', import.meta.url)),
            `--registry=http://127.0.0.1:${registry.address().port}`, '--fetch-timeout=100'], { cwd: directory, signal: context.signal });
        let output = '';
        child.stdout.on('data', data => { output += data; });
        child.stderr.on('data', data => { output += data; });
        const code = await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', resolve); });
        assert.equal(code, 0, output);
        assert.match(output, /temporary network failure \(ETIMEDOUT\)/);
        assert.equal(requests, 2, output);
    } finally {
        registry.closeAllConnections();
        await new Promise(resolve => registry.close(resolve));
        await rm(directory, { recursive: true, force: true });
    }
});
