import { DocsLayout } from 'fumadocs-ui/layouts/docs';
import { baseOptions } from '@/lib/layout.shared';
import { source } from '@/lib/source';
import type { ReactNode } from 'react';
export default function Layout({ children }: { children: ReactNode }) {
  return <DocsLayout {...baseOptions()} tree={source.pageTree} sidebar={{ banner: <div className="sidebar-note"><span className="status-dot" /> 开发预览 · 能力逐步开放</div> }}>{children}</DocsLayout>;
}
