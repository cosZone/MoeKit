import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { reviewAudit, KNOWN_ADVISORY } from './audit-policy.mjs';

const lock = JSON.parse(readFileSync(new URL('../package-lock.json', import.meta.url), 'utf8'));
for (const production of [true, false]) {
  const args = ['audit', '--json', ...(production ? ['--omit=dev'] : [])];
  const result = spawnSync(process.platform === 'win32' ? 'npm.cmd' : 'npm', args, {
    encoding: 'utf8', timeout: 120_000, maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error || (result.status !== 0 && result.status !== 1)) {
    throw new Error('npm audit failed to complete; dependency status is unknown.');
  }
  const report = JSON.parse(result.stdout);
  // Preserve the full report in CI logs, including the known exception.
  console.log(JSON.stringify(report, null, 2));
  const accepted = reviewAudit(report, lock, { production });
  if (accepted.length > 0) {
    const message = `Known development-only braces advisory remains (${accepted.length} propagated entries): ${KNOWN_ADVISORY}. See website/SECURITY.md; review an upstream fix before removing the exception.`;
    console.warn(process.env.GITHUB_ACTIONS === 'true' ? `::warning::${message}` : message);
  } else {
    console.log(`${production ? 'Production' : 'Full'} dependency audit: no advisories.`);
  }
}
