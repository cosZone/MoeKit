import { releases } from '@/lib/source';
import { DocsBody, DocsDescription, DocsPage, DocsTitle } from 'fumadocs-ui/layouts/docs/page';
import { notFound } from 'next/navigation';
import { getMDXComponents } from '@/components/mdx';
import type { Metadata } from 'next';

type Props = { params: Promise<{ version: string }> };
export function generateStaticParams() { return releases.getPages().map((p) => ({ version: p.slugs[0] })); }
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const page = releases.getPage([(await params).version]);
  if (!page) notFound();
  return { title: page.data.title, description: page.data.description };
}
export default async function Page({ params }: Props) {
  const page = releases.getPage([(await params).version]);
  if (!page) notFound();
  const Content = page.data.body;
  return <DocsPage toc={page.data.toc}><DocsTitle>{page.data.title}</DocsTitle><DocsDescription>{page.data.description}</DocsDescription><p className="release-state-banner">{page.data.status === 'unreleased' ? '尚未发布 · 版本内容与日期仍可能调整' : `${page.data.status === 'prerelease' ? '预览发布' : '已发布'} · ${page.data.date} · UTC`}</p><DocsBody><Content components={getMDXComponents()} /></DocsBody><a className="source-link" href={`https://github.com/cosZone/MoeKit/blob/main/website/content/changelog/${page.path}`}>查看原始 Markdown ↗</a></DocsPage>;
}
