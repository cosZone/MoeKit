import Link from 'next/link';
import Image from 'next/image';
import { ArrowRight, FolderGit2, ListChecks, PanelsTopLeft, ShieldCheck, Terminal, Activity, BookOpen, ExternalLink } from 'lucide-react';

const workspaces = [
  { icon: FolderGit2, title: 'Projects', label: '项目，不再散落', detail: '选择目录，发现 Git 项目。搜索、置顶和定位都在一个原生列表里。', href: '/docs/projects', tag: '已实现 · 只读发现' },
  { icon: PanelsTopLeft, title: 'Tools', label: '常用工具，各就其位', detail: '从 Mole 空间报告到进程与端口，把已知结果和未知状态分开呈现。', href: '/docs/mole', tag: '已实现 · 报告与快照' },
  { icon: ListChecks, title: 'Tasks', label: '每一步，都有来处', detail: '查看本次会话的任务状态、取消与诊断。让过程像结果一样清楚。', href: '/docs/tasks', tag: '已实现 · 会话内记录' },
];

export default function HomePage() {
  return (
    <main className="landing">
      <section className="hero" aria-labelledby="hero-title">
        <div>
          <p className="eyebrow"><span className="status-dot" /> 原生 macOS 工作台 · 开发预览</p>
          <h1 id="hero-title">给常用工具<br /><span>一个安静的家。</span></h1>
          <p className="hero-description">项目、工具与任务，收进同一个工作台。<br className="desktop-break" />从看清发生了什么开始，再一步步走向安全执行。</p>
          <div className="hero-actions">
            <Link className="primary-action" href="/docs">开始了解 <ArrowRight size={16} /></Link>
            <Link className="secondary-action" href="/docs/installation">获取预览 <ExternalLink size={15} /></Link>
          </div>
          <p className="hero-footnote">macOS 15+ <span>·</span> SwiftUI / AppKit <span>·</span> 本地优先</p>
        </div>
        <div className="hero-visual" aria-label="MoeKit 品牌图标与工作区结构示意">
          <div className="visual-topline"><span>MoeKit</span><span>WORKSPACE</span></div>
          <Image className="hero-icon" src="/icon.svg" width={176} height={176} alt="MoeKit：抱着收纳盒的小幽灵" priority />
          <p className="visual-title">小小工具箱，清楚每一步</p>
          <div className="workspace-tabs"><span><FolderGit2 size={15} /> Projects</span><span><Terminal size={15} /> Tools</span><span><ListChecks size={15} /> Tasks</span></div>
          <div className="visual-bottomline"><ShieldCheck size={14} /> 受限原生操作 · 复查与确认</div>
        </div>
      </section>

      <section className="workspace-section" aria-labelledby="workspace-heading">
        <div className="section-heading"><div><p className="eyebrow">ONE WORKSPACE, THREE PLACES</p><h2 id="workspace-heading">少一些切换，多一点清楚</h2></div><Link href="/docs/status">查看能力边界 <ArrowRight size={15} /></Link></div>
        <div className="workspace-grid">{workspaces.map(({ icon: Icon, title, label, detail, href, tag }) => <Link className="workspace-card" href={href} key={title}><Icon className="card-icon" size={22} /><p className="card-kicker">{title}</p><h3>{label}</h3><p>{detail}</p><span className="card-tag">{tag}<ArrowRight size={14} /></span></Link>)}</div>
      </section>

      <section className="honesty-panel" aria-labelledby="preview-heading">
        <div><Activity size={20} /><h2 id="preview-heading">预览版，把边界写在前面</h2><p>已支持项目发现、Mole 分析、逐次确认的 Git／缓存／精确进程操作，以及签名应用更新。旧版需先手动安装一次；广域清理、卸载和任意命令仍未开放。</p></div>
        <Link href="/docs/status">完整功能状态 <ArrowRight size={15} /></Link>
      </section>
      <footer className="landing-footer"><span>MoeKit · 一个正在长大的个人工具箱</span><div><Link href="/changelog"><BookOpen size={14} /> 更新日志</Link><a href="https://github.com/cosZone/MoeKit">GitHub <ExternalLink size={13} /></a></div></footer>
    </main>
  );
}
