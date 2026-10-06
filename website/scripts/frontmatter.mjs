import { isMap, parseDocument } from 'yaml';

// Test-only reader for the repository's YAML-frontmatter Markdown files.
// Delimiters are whole lines; YAML syntax is handled by the pinned library.
export function readFrontmatter(source) {
  if (typeof source !== 'string') throw new TypeError('Markdown source must be a string.');
  const opening = /^(?:\uFEFF)?---\r?\n/.exec(source);
  if (!opening) throw new SyntaxError('Markdown must start with YAML frontmatter.');
  const rest = source.slice(opening[0].length);
  const closing = /^---(?:\r?\n|$)/m.exec(rest);
  if (!closing) throw new SyntaxError('YAML frontmatter closing delimiter is missing.');
  const document = parseDocument(rest.slice(0, closing.index), {
    schema: 'core',
    strict: true,
    stringKeys: true,
    uniqueKeys: true,
    resolveKnownTags: false,
  });
  if (document.errors.length || document.warnings.length || !isMap(document.contents)) {
    throw new SyntaxError('YAML frontmatter must be one valid mapping without unsupported tags.');
  }
  return {
    data: document.toJS({ maxAliasCount: 0 }),
    content: rest.slice(closing.index + closing[0].length),
  };
}
