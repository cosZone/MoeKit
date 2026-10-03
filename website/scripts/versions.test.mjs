import test from 'node:test';
import assert from 'node:assert/strict';
import { compareVersionsNewestFirst } from '../lib/versions.mjs';

test('final releases sort before previews of the same version', () => {
  const input = ['0.1.0-preview.1', '0.2.0-preview.2', '0.1.0', '0.2.0-preview.10', '0.2.0', '0.2.0-preview.1'];
  assert.deepEqual(input.toSorted(compareVersionsNewestFirst), ['0.2.0', '0.2.0-preview.10', '0.2.0-preview.2', '0.2.0-preview.1', '0.1.0', '0.1.0-preview.1']);
});
test('major, minor and patch comparisons use numeric precedence', () => {
  const input = ['0.10.0', '1.0.0-preview.1', '0.2.99', '0.10.1', '1.0.0'];
  assert.deepEqual(input.toSorted(compareVersionsNewestFirst), ['1.0.0', '1.0.0-preview.1', '0.10.1', '0.10.0', '0.2.99']);
  assert.equal(compareVersionsNewestFirst('0.1.0', '0.1.0'), 0);
  assert.equal(compareVersionsNewestFirst('0.1.0-preview.1', '0.1.0-preview.1'), 0);
});
test('unsupported versions fail visibly', () => {
  assert.throws(() => compareVersionsNewestFirst('banana', '0.1.0'));
});

test('the unreleased staging record precedes versioned releases', () => {
  assert.deepEqual(['0.1.0', 'unreleased', '0.2.0-preview.1'].toSorted(compareVersionsNewestFirst), ['unreleased', '0.2.0-preview.1', '0.1.0']);
  assert.equal(compareVersionsNewestFirst('unreleased', 'unreleased'), 0);
});
