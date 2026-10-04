// A temporary exception for one advisory in one verified development-only chain.
// Any new advisory, location, version, or production dependency requires review.
const EXPECTED_CHAIN = {
  'eslint-config-next': { version: '16.3.8', via: '@next/eslint-plugin-next' },
  '@next/eslint-plugin-next': { version: '16.3.8', via: 'fast-glob' },
  'fast-glob': { version: '3.3.1', via: 'micromatch' },
  micromatch: { version: '4.0.8', via: 'braces' },
  braces: { version: '3.0.3' },
};
export const KNOWN_ADVISORY = 'https://github.com/advisories/GHSA-vfj7-8cjw-p6xm';

export function reviewAudit(report, lock, { production = false } = {}) {
  if (report.error || report.auditReportVersion !== 2 || !report.vulnerabilities ||
      typeof report.vulnerabilities !== 'object' || Array.isArray(report.vulnerabilities)) {
    throw new Error('npm audit did not return a supported report; no exception applied.');
  }
  const entries = Object.entries(report.vulnerabilities);
  if (production && entries.length > 0) throw new Error('Production dependency advisories must be resolved.');
  for (const [name, finding] of entries) {
    const expected = EXPECTED_CHAIN[name];
    const node = `node_modules/${name}`;
    const pkg = lock.packages?.[node];
    if (!expected || !pkg || pkg.dev !== true || pkg.version !== expected.version ||
        finding.name !== name || !Array.isArray(finding.nodes) ||
        finding.nodes.length !== 1 || finding.nodes[0] !== node ||
        !Array.isArray(finding.via) || finding.via.length !== 1) {
      throw new Error(`Unreviewed dependency advisory or changed exposure: ${name}`);
    }
    const via = finding.via[0];
    if (expected.via) {
      if (via !== expected.via || !Object.hasOwn(report.vulnerabilities, via)) {
        throw new Error(`Unreviewed advisory chain: ${name}`);
      }
    } else if (typeof via !== 'object' || via === null || via.name !== 'braces' || via.url !== KNOWN_ADVISORY) {
      throw new Error('Unreviewed braces advisory.');
    }
  }
  return entries.map(([name]) => name);
}
