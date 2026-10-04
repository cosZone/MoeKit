import assert from 'node:assert/strict';
import test from 'node:test';
import { reviewAudit, KNOWN_ADVISORY } from './audit-policy.mjs';

function fixture() {
  const specs = [
    ['eslint-config-next', '16.3.8', '@next/eslint-plugin-next'],
    ['@next/eslint-plugin-next', '16.3.8', 'fast-glob'],
    ['fast-glob', '3.3.1', 'micromatch'],
    ['micromatch', '4.0.8', 'braces'],
    ['braces', '3.0.3', { name: 'braces', url: KNOWN_ADVISORY }],
  ];
  return {
    report: { auditReportVersion: 2, vulnerabilities: Object.fromEntries(specs.map(([name, , via]) => [name, { name, nodes: [`node_modules/${name}`], via: [via] }])) },
    lock: { packages: Object.fromEntries(specs.map(([name, version]) => [`node_modules/${name}`, { version, dev: true }])) },
  };
}

test('audit accepts no advisories and the exact reviewed development chain', () => {
  const { report, lock } = fixture();
  assert.equal(reviewAudit(report, lock).length, 5);
  assert.deepEqual(reviewAudit({ auditReportVersion: 2, vulnerabilities: {} }, lock, { production: true }), []);
});

test('audit fails on production exposure, new advisories and changed dependency boundaries', () => {
  const changes = [
    ({ report }) => { report.vulnerabilities.braces.via[0].url = 'https://github.com/advisories/NEW'; },
    ({ report }) => { report.vulnerabilities.braces.via.push({ name: 'braces', url: 'new' }); },
    ({ report }) => { report.vulnerabilities.braces.nodes.push('node_modules/other/node_modules/braces'); },
    ({ report }) => { report.vulnerabilities.other = { name: 'other', via: ['braces'], nodes: ['node_modules/other'] }; },
    ({ report }) => { delete report.vulnerabilities.braces; },
    ({ lock }) => { lock.packages['node_modules/braces'].dev = false; },
    ({ lock }) => { lock.packages['node_modules/braces'].version = '3.0.4'; },
    ({ report }) => { report.error = { message: 'registry unavailable' }; },
    ({ report }) => { delete report.vulnerabilities; },
    ({ report }) => { report.auditReportVersion = 3; },
  ];
  for (const mutate of changes) {
    const data = fixture();
    mutate(data);
    assert.throws(() => reviewAudit(data.report, data.lock));
  }
  const { report, lock } = fixture();
  assert.throws(() => reviewAudit(report, lock, { production: true }));
});
