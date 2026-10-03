const versionPattern = /^(\d+)\.(\d+)\.(\d+)(?:-preview\.(\d+))?$/;

/** Sort supported SemVer versions newest first, including final-after-preview precedence. */
export function compareVersionsNewestFirst(a, b) {
  if (a === 'unreleased') return b === 'unreleased' ? 0 : -1;
  if (b === 'unreleased') return 1;
  const left = versionPattern.exec(a);
  const right = versionPattern.exec(b);
  if (!left || !right) throw new Error('Unsupported release version');
  for (let i = 1; i <= 3; i++) {
    const x = BigInt(left[i]);
    const y = BigInt(right[i]);
    if (x !== y) return x > y ? -1 : 1;
  }
  if (left[4] === undefined) return right[4] === undefined ? 0 : -1;
  if (right[4] === undefined) return 1;
  const x = BigInt(left[4]);
  const y = BigInt(right[4]);
  return x === y ? 0 : x > y ? -1 : 1;
}
