import { defineConfig, defineDocs } from 'fumadocs-mdx/config';
import { z } from 'zod';

export const docs = defineDocs({ dir: 'content/docs' });
export const changelog = defineDocs({
  dir: 'content/changelog',
  docs: {
    schema: z.object({
      title: z.string(),
      description: z.string(),
      version: z.union([z.literal("unreleased"), z.string().regex(/^\d+\.\d+\.\d+(?:-preview\.\d+)?$/)]),
      status: z.enum(['unreleased', 'prerelease', 'released']),
      date: z.string().optional(),
      sourceCommit: z.string().regex(/^[a-f0-9]{40}$/).optional(),
      releaseUrl: z.url().optional(),
    }),
  },
});
export default defineConfig();
