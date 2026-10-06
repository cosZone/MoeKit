import test from 'node:test';
import assert from 'node:assert/strict';
import { readFrontmatter } from './frontmatter.mjs';

test('frontmatter preserves Chinese text, quoted versions, dates and YAML scalar types', () => {
  const { data } = readFrontmatter(`---
title: "版本: 预览 #10"
version: "0.1.0-preview.10"
date: "2026-10-06"
unquotedDate: 2026-10-06
status: unreleased
enabled: true
count: 10
---
正文`);
  assert.deepEqual(data, {
    title: '版本: 预览 #10', version: '0.1.0-preview.10', date: '2026-10-06',
    unquotedDate: '2026-10-06', status: 'unreleased', enabled: true, count: 10,
  });
});

test('frontmatter preserves the exact Markdown body with later rules and fenced examples', () => {
  const body = '\n## 正文\n\n---\n```yaml\n---\ntitle: example\n---\n```\n';
  const source = `---\ntitle: Page\ndescription: |\n  First line\n  Second line\n---\n${body}`;
  const result = readFrontmatter(source);
  assert.equal(result.data.description, 'First line\nSecond line\n');
  assert.equal(result.content, body);
});

test('frontmatter supports CRLF, an optional BOM and a closing delimiter at EOF', () => {
  const body = '\r\n## Body\r\n---\r\n';
  assert.deepEqual(readFrontmatter(`\uFEFF---\r\ntitle: Page\r\n---\r\n${body}`), {
    data: { title: 'Page' }, content: body,
  });
  assert.deepEqual(readFrontmatter('---\ntitle: Page\n---'), { data: { title: 'Page' }, content: '' });
});

test('frontmatter rejects missing, incomplete and nonstandard delimiters', () => {
  for (const source of ['', 'title: Page', '\n---\ntitle: Page\n---',
    '---\ntitle: Page', '---yaml\ntitle: Page\n---', '---\ntitle: Page\n---suffix',
    '---\ntitle: Page\n  ---']) {
    assert.throws(() => readFrontmatter(source), SyntaxError);
  }
  assert.throws(() => readFrontmatter(null), TypeError);
});

test('frontmatter rejects duplicate, malformed, non-mapping and tagged metadata', () => {
  for (const metadata of ['', '- first\n- second', 'scalar', 'null',
    'title: first\ntitle: second', 'title: [unclosed', 'title: !custom value',
    'date: !!timestamp 2026-10-06', '? [complex, key]\n: value']) {
    assert.throws(() => readFrontmatter(`---\n${metadata}\n---\nbody`), SyntaxError);
  }
});

test('frontmatter rejects aliases instead of expanding them', () => {
  assert.throws(() => readFrontmatter('---\ntitle: &title Page\ndescription: *title\n---\nbody'));
});
