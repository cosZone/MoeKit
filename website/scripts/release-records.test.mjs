import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { readFrontmatter } from './frontmatter.mjs';
const root = new URL('../', import.meta.url);
const record = new URL('release-records/0.1.0-preview.11/', root);
const metadata = JSON.parse(readFileSync(new URL('provenance.json', record), 'utf8'));
const digest = (data) => createHash('sha256').update(data).digest('hex');

test('published preview.11 signed records retain their original source-bound bytes', () => {
  assert.equal(metadata.sourceCommit, '6b23cb267bdb140fa8f2834638658dbc60dadf90');
  const signed = readFileSync(new URL(metadata.signedNotes.path, record));
  assert.equal(digest(signed), '53726a8d188d325725f445adbcb183d703f66606f320fb1a2fc40c58848fddaf');
  assert.equal(digest(signed), metadata.signedNotes.sha256);
  const originalBody = readFileSync(new URL(metadata.originalReleaseBody.path, record));
  assert.equal(digest(originalBody), metadata.originalReleaseBody.sha256);
  assert.equal(metadata.originalReleaseBody.sha256, '15b40ac22057f3110caa6ce49f0c28f72e7a3d68ac6842eb300724a27659b6c5');
  assert.equal(readFrontmatter(signed.toString()).data.status, 'unreleased');
  assert.equal(metadata.assets.length, 5);
  assert.equal(metadata.assets.find((a) => a.name === 'appcast.xml').sha256, 'f396042e0e85b92aa06dc56acc3e3f5ec483cc1b741f3b1045cc25adf3ddb5bb');
});

test('concise display notes are distinct from immutable signed notes and use verified release metadata', () => {
  const display = readFileSync(new URL(metadata.displayNotes.path, root));
  assert.equal(metadata.displayNotes.presentationOnly, true);
  assert.notEqual(digest(display), metadata.signedNotes.sha256);
  const { data } = readFrontmatter(display.toString());
  assert.equal(data.version, metadata.version);
  assert.equal(data.status, 'prerelease');
  assert.equal(data.sourceCommit, metadata.sourceCommit);
  assert.equal(data.releaseUrl, metadata.releaseUrl);
  assert.equal(data.date, metadata.publishedAt.slice(0, 10));
});
