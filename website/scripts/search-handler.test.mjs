import assert from 'node:assert/strict';
import test from 'node:test';
import { createSearchHandler } from '../lib/search-handler.mjs';

function fixture() {
  const calls = [];
  const GET = createSearchHandler(async (...args) => {
    calls.push(args);
    return [{ id: '/docs/projects', url: '/docs/projects', content: '项目 Mole' }];
  });
  return { calls, request: (query = '') => GET(new Request(`http://localhost/api/search${query}`)) };
}

test('ordinary Chinese and English search receives only bounded full-text options', async () => {
  const { calls, request } = fixture();
  for (const query of ['项目', '进程', 'Mole', '0.1.0-preview.1']) {
    assert.equal((await request(`?query=${encodeURIComponent(query)}&locale=zh-CN`)).status, 200);
    assert.deepEqual(calls.at(-1), [query, { mode: 'full', locale: 'zh-CN', limit: 60 }]);
  }
  await request('?query=Mole&mode=full&limit=1&locale=&tag=');
  assert.deepEqual(calls.at(-1), ['Mole', { mode: 'full', locale: 'zh-CN', limit: 1 }]);
});

test('missing, empty and whitespace-only queries stay empty without invoking search', async () => {
  const { calls, request } = fixture();
  for (const query of ['', '?query=', '?query=%20%20']) {
    const response = await request(query);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), []);
  }
  assert.equal(calls.length, 0);
});

test('query and result boundaries are inclusive', async () => {
  const { calls, request } = fixture();
  for (const limit of [1, 60]) {
    const response = await request(`?query=${encodeURIComponent('项'.repeat(256))}&limit=${limit}`);
    assert.equal(response.status, 200);
    assert.equal(calls.at(-1)[1].limit, limit);
  }
  assert.equal(calls.length, 2);
});

test('invalid public inputs return identical controlled 400 responses before searching', async () => {
  const { calls, request } = fixture();
  const invalid = [
    '?query=Mole&mode=vector', '?mode=vector', '?query=Mole&mode=fulltext',
    '?query=Mole&mode=hybrid', '?query=Mole&mode=',
    ...['-1', '0', '61', '100', '1.5', 'NaN', 'Infinity', '1e1', '', '01', '%201', '+1', '999999999999999999999'].map((limit) => `?query=Mole&limit=${limit}`),
    `?query=${'a'.repeat(257)}`, `?query=${encodeURIComponent('项'.repeat(257))}`,
    '?query=Mole&locale=en', '?query=Mole&tag=docs',
    `?query=Mole&locale=${'a'.repeat(4000)}`, `?query=Mole&tag=${'a'.repeat(4000)}`,
    '?query=Mole&query=项目', '?query=Mole&mode=full&mode=vector',
    '?query=Mole&limit=1&limit=60', '?query=Mole&locale=zh-CN&locale=zh-CN',
    '?query=Mole&tag=&tag=', '?query=Mole&unexpected=true',
    `?query=Mole&unexpected=${'a'.repeat(4096)}`,
  ];
  for (const query of invalid) {
    const response = await request(query);
    assert.equal(response.status, 400, query.slice(0, 100));
    assert.match(response.headers.get('content-type'), /^application\/json/);
    assert.equal(await response.text(), '{"error":"invalid_search_request"}');
  }
  assert.equal(calls.length, 0);
  assert.equal((await request('?query=Mole')).status, 200);
  assert.equal(calls.length, 1);
});
