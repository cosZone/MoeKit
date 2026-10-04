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

// These requests hit the real production route (also run inside the CI container).
for (const query of ['', '?query=', '?query=%20%20']) {
  const response = await fetch(new URL(`/api/search${query}`, base));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), []);
}
for (const query of ['Mole', '项目']) {
  const response = await fetch(new URL(`/api/search?query=${encodeURIComponent(query)}&mode=full&limit=1&locale=zh-CN&tag=`, base));
  assert.equal(response.status, 200);
  const results = await response.json();
  assert.equal(results.length, 1);
}
const invalidSearches = [
  '?query=Mole&mode=vector', '?mode=vector', '?query=Mole&mode=fulltext',
  '?query=Mole&mode=unexpected', '?query=Mole&mode=',
  ...['-1', '0', '61', '1.5', 'NaN', 'Infinity', '1e1', '', '01', '%201', '+1'].map((limit) => `?query=Mole&limit=${limit}`),
  `?query=${'a'.repeat(257)}`, `?query=${encodeURIComponent('项'.repeat(257))}`,
  '?query=Mole&locale=en', '?query=Mole&tag=docs',
  `?query=Mole&locale=${'a'.repeat(4096)}`, `?query=Mole&tag=${'a'.repeat(4096)}`,
  '?query=Mole&query=项目', '?query=Mole&mode=full&mode=vector',
  '?query=Mole&limit=1&limit=60', '?query=Mole&locale=zh-CN&locale=zh-CN',
  '?query=Mole&tag=&tag=', '?query=Mole&unexpected=true',
];
for (const query of invalidSearches) {
  const response = await fetch(new URL(`/api/search${query}`, base));
  assert.equal(response.status, 400, query.slice(0, 100));
  assert.match(response.headers.get('content-type'), /^application\/json/);
  assert.equal(await response.text(), '{"error":"invalid_search_request"}');
}
// Expected input failures must not leave search or the process unusable.
const recovered = await fetch(new URL('/api/search?query=Mole&locale=zh-CN', base));
assert.equal(recovered.status, 200);
assert.ok((await recovered.json()).length > 0);
assert.equal((await fetch(new URL('/health', base))).status, 200);
console.log('All search validation HTTP checks passed.');
