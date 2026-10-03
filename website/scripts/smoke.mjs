import assert from 'node:assert/strict';
const base = process.env.SMOKE_BASE_URL ?? 'http://127.0.0.1:3000';
const paths = ['/', '/docs', '/docs/installation', '/docs/status', '/docs/projects', '/docs/mole', '/docs/processes', '/docs/tasks', '/docs/privacy', '/docs/development', '/docs/deployment', '/changelog', '/changelog/0.1.0-preview.1', '/changelog/unreleased'];
for (const path of paths) {
  const response = await fetch(new URL(path, base));
  assert.equal(response.status, 200, path);
  const body = await response.text();
  assert.match(body, /<html[^>]+lang="zh-CN"/, path);
  assert.match(body, /MoeKit/, path);
  assert.ok(!/Internal Server Error|Application error:/.test(body), path);
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff', path);
  console.log(`OK ${path}`);
}
const missing = await fetch(new URL('/docs/this-page-does-not-exist', base));
assert.equal(missing.status, 404);
const health = await fetch(new URL('/health', base));
assert.equal(health.status, 200);
assert.deepEqual(await health.json(), { status: 'ok', service: 'moekit-docs' });
for (const query of ['项目', '进程', 'Mole', '0.1.0-preview.1']) {
  const response = await fetch(new URL(`/api/search?query=${encodeURIComponent(query)}&locale=zh-CN`, base));
  assert.equal(response.status, 200);
  const results = await response.json();
  assert.ok(Array.isArray(results) && results.length > 0, `No search results for ${query}`);
  for (const result of results) assert.ok(result.url.startsWith('/docs') || result.url.startsWith('/changelog'));
  console.log(`OK search: ${query}`);
}
const empty = await fetch(new URL('/api/search?query=zzzzunmatchable123456789&locale=zh-CN', base));
assert.deepEqual(await empty.json(), []);
console.log('All production HTTP smoke checks passed.');
