import { source, releases } from '@/lib/source';
import { createSearchAPI } from 'fumadocs-core/search/server';
import { createSearchHandler } from '@/lib/search-handler.mjs';

const { search } = createSearchAPI('advanced', {
  indexes: [...source.getPages(), ...releases.getPages()].map((page) => ({
    title: page.data.title, description: page.data.description,
    id: page.url, url: page.url, locale: 'zh-CN', structuredData: page.data.structuredData,
  })),
});

export const GET = createSearchHandler(search);
