import { source } from '@/lib/source';
import { DocsBody, DocsDescription, DocsPage, DocsTitle } from 'fumadocs-ui/layouts/docs/page';
import { notFound } from 'next/navigation';
import { getMDXComponents } from '@/components/mdx';
import type { Metadata } from 'next';

type Props = { params: Promise<{ slug?: string[] }> };
export function generateStaticParams() { return source.generateParams(); }
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const page = source.getPage((await params).slug);
  if (!page) notFound();
  return { title: page.data.title, description: page.data.description };
}
export default async function Page({ params }: Props) {
  const page = source.getPage((await params).slug);
  if (!page) notFound();
  const Content = page.data.body;
  return <DocsPage toc={page.data.toc}><DocsTitle>{page.data.title}</DocsTitle><DocsDescription>{page.data.description}</DocsDescription><DocsBody><Content components={getMDXComponents()} /></DocsBody><a className="source-link" href={`https://github.com/cosZone/MoeKit/blob/main/website/content/docs/${page.path}`}>在 GitHub 查看此页源码 ↗</a></DocsPage>;
}
