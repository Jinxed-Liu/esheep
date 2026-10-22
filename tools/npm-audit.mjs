#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const transientCodes = new Set(['ETIMEDOUT', 'ECONNRESET', 'EAI_AGAIN', 'ECONNREFUSED', 'ENOTFOUND', 'E502', 'E503', 'E504']);

export async function audit({ args = [], run = spawnSync, wait = ms => new Promise(resolve => setTimeout(resolve, ms)),
    output = text => process.stdout.write(text), attempts = 3 } = {}) {
    for (let attempt = 1; attempt <= attempts; attempt++) {
        const result = run('npm', ['audit', '--json', '--fetch-retries=0', '--fetch-timeout=20000', ...args],
            { encoding: 'utf8', timeout: 30000 });
        output(result.stdout || '');
        output(result.stderr || '');
        if (result.status === 0) return 0;
        let report;
        try { report = JSON.parse(result.stdout); } catch { /* Non-JSON failures remain failures. */ }
        // Never retry a vulnerability finding into a pass or lower its severity gate.
        if (report?.metadata?.vulnerabilities?.total > 0 || Object.keys(report?.vulnerabilities ?? {}).length > 0) {
            return result.status || 1;
        }
        // npm's audit command sometimes strips the FetchError code and emits
        // only a top-level message/statusCode (unlike npm install).
        const code = report?.error?.code || result.error?.code
            || (/^network timeout at:/i.test(report?.message ?? '') ? 'ETIMEDOUT' : undefined)
            || ([502, 503, 504].includes(report?.statusCode) ? `E${report.statusCode}` : undefined);
        if (!transientCodes.has(code) || attempt === attempts) return result.status || 1;
        output(`npm audit temporary network failure (${code}); retry ${attempt}/${attempts - 1}\n`);
        await wait(2000 * attempt);
    }
    return 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    process.exitCode = await audit({ args: process.argv.slice(2) });
}
