import { readFileSync, readdirSync } from 'node:fs';
import { resolve, basename } from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';
import matter from 'gray-matter';

const root = resolve(import.meta.dirname, '..');
const docs = readdirSync(`${root}/content/docs`).filter((f) => /\.mdx?$/.test(f));
const versions = readdirSync(`${root}/content/changelog`).filter((f) => f.endsWith('.md'));
const route = (name) => name === 'index' ? '/docs' : `/docs/${name}`;
const routes = new Set(['/', '/changelog', ...docs.map((f) => route(f.replace(/\.mdx?$/, ''))), ...versions.map((f) => `/changelog/${basename(f, '.md')}`)]);
const all = [...docs.map((f) => `content/docs/${f}`), ...versions.map((f) => `content/changelog/${f}`)];

test('all Markdown pages have meaningful metadata and working internal routes', () => {
  for (const file of all) {
    const text = readFileSync(`${root}/${file}`, 'utf8');
    const { data } = matter(text);
    assert.ok(data.title && data.description, `${file}: missing title/description`);
    for (const [, href] of text.matchAll(/\]\((\/[^)\s]+)\)/g)) {
      assert.ok(routes.has(href.split('#')[0]), `${file}: broken internal link ${href}`);
    }
  }
});

test('sidebar lists every documentation page exactly once', () => {
  const meta = JSON.parse(readFileSync(`${root}/content/docs/meta.json`, 'utf8'));
  const pages = meta.pages.filter((p) => !p.startsWith('---'));
  assert.deepEqual(pages.toSorted(), docs.map((f) => f.replace(/\.mdx?$/, '')).toSorted());
});

test('version records stay plain Markdown with honest release metadata', () => {
  assert.ok(versions.length > 0);
  assert.equal(readdirSync(`${root}/content/changelog`).some((f) => f.endsWith('.mdx')), false);
  for (const file of versions) {
    const { data, content } = matter(readFileSync(`${root}/content/changelog/${file}`, 'utf8'));
    assert.equal(data.version, basename(file, '.md'));
    assert.match(data.version, /^(?:unreleased|\d+\.\d+\.\d+(?:-preview\.\d+)?)$/);
    if (data.version === 'unreleased') assert.equal(data.status, 'unreleased');
    assert.ok(['unreleased', 'prerelease', 'released'].includes(data.status));
    assert.doesNotMatch(content, /^(import|export)\s/m);
    assert.doesNotMatch(content, /<\/?[A-Z][\w]*(?:\s|>|\/)/);
    if (data.status === 'unreleased') {
      for (const key of ['date', 'sourceCommit', 'releaseUrl']) assert.equal(data[key], undefined, `${file}: unreleased ${key}`);
    } else {
      const date = String(data.date instanceof Date ? data.date.toISOString().slice(0, 10) : data.date);
      assert.match(date, /^\d{4}-\d{2}-\d{2}$/);
      assert.equal(new Date(`${date}T00:00:00Z`).toISOString().slice(0, 10), date);
      assert.match(data.sourceCommit, /^[a-f0-9]{40}$/);
      assert.equal(data.releaseUrl, `https://github.com/cosZone/MoeKit/releases/tag/v${data.version}`);
      assert.equal(data.status === 'prerelease', data.version.includes('-preview.'));
    }
  }
});

test('direct dependency ranges are pinned and match the committed lockfile', () => {
  const pkg = JSON.parse(readFileSync(`${root}/package.json`, 'utf8'));
  const lock = JSON.parse(readFileSync(`${root}/package-lock.json`, 'utf8'));
  for (const section of ['dependencies', 'devDependencies']) {
    for (const [name, version] of Object.entries(pkg[section])) {
      assert.match(version, /^\d+\.\d+\.\d+(?:[-+].+)?$/);
      assert.equal(lock.packages[''][section][name], version);
      assert.equal(lock.packages[`node_modules/${name}`].version, version);
    }
  }
});
