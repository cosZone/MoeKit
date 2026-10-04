// Keep the public contract narrower than Fumadocs' generic search endpoint.
const MAX_URL_LENGTH = 4096;
const MAX_QUERY_LENGTH = 256; // UTF-16 code units, before trimming.
const MAX_RESULTS = 60;
const PARAMETERS = new Set(['query', 'mode', 'limit', 'locale', 'tag']);

function invalidRequest() {
  // Do not reflect user input or expose a dependency exception/stack.
  return Response.json({ error: 'invalid_search_request' }, { status: 400 });
}

/**
 * @param {(query: string, options: import('fumadocs-core/search/server').QueryOptions) => Promise<unknown[]>} search
 */
export function createSearchHandler(search) {
  /** @param {Request} request */
  return async function GET(request) {
    if (request.url.length > MAX_URL_LENGTH) return invalidRequest();
    const params = new URL(request.url).searchParams;
    for (const key of params.keys()) {
      if (!PARAMETERS.has(key) || params.getAll(key).length !== 1) return invalidRequest();
    }

    const query = params.get('query') ?? '';
    const mode = params.get('mode');
    const locale = params.get('locale');
    const tag = params.get('tag');
    const rawLimit = params.get('limit');
    // 'full' is the Fumadocs API spelling; the engine's 'fulltext' is internal.
    // This site has one locale, no tag filters, and no vector index/provider.
    if (query.length > MAX_QUERY_LENGTH || (mode !== null && mode !== 'full') ||
        (locale !== null && locale !== '' && locale !== 'zh-CN') ||
        (tag !== null && tag !== '')) return invalidRequest();
    if (rawLimit !== null && !/^[1-9][0-9]?$/.test(rawLimit)) return invalidRequest();
    const limit = rawLimit === null ? MAX_RESULTS : Number(rawLimit);
    if (limit > MAX_RESULTS) return invalidRequest();

    if (query.trim().length === 0) return Response.json([]);
    // Pass only app-owned options. Never forward the raw request/options bag.
    return Response.json(await search(query, { mode: 'full', locale: 'zh-CN', limit }));
  };
}
