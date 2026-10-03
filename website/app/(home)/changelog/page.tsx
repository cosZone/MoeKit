import Link from 'next/link';
import { compareVersionsNewestFirst } from '@/lib/versions.mjs';
import { ArrowUpRight, FileText } from 'lucide-react';
import { releases } from '@/lib/source';
import type { Metadata } from 'next';
export const metadata: Metadata = { title: '更新日志', description: '每个版本，一份普通 Markdown。区分开发计划、预览版与正式发布。' };
const statusLabels = { unreleased: '尚未发布', prerelease: '预览发布', released: '已发布' };
export default function ChangelogPage() {
  const pages = releases.getPages().sort((a, b) => compareVersionsNewestFirst(a.data.version, b.data.version));
  return <main className="release-index"><p className="eyebrow">CHANGELOG</p><h1>每一步，都记下来。</h1><p className="release-intro">一版一份 Markdown，保留变化，也保留当时的边界。<br />开发中的条目不代表已有可下载的发布产物。</p><div className="release-list">{pages.map((page) => <Link className="release-row" key={page.url} href={page.url}><FileText size={20} /><div><div className="release-title"><h2>{page.data.version === 'unreleased' ? '后续变更' : page.data.version}</h2><span className={`release-status ${page.data.status}`}>{statusLabels[page.data.status]}</span></div><p>{page.data.description}</p><small>{page.data.date ? `${page.data.date} · UTC` : '发布日期待确认'}</small></div><ArrowUpRight size={18} /></Link>)}</div><p className="release-note">实际交付以 <a href="https://github.com/cosZone/MoeKit/releases">GitHub Releases ↗</a> 中的产物与校验信息为准。</p></main>;
}
