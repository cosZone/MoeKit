import Link from 'next/link';
export default function NotFound() {
  return <main className="not-found"><p className="eyebrow">404 · PAGE NOT FOUND</p><h1>这一页还没有收进工具箱</h1><p>地址可能已变化，或这个版本还没有文档。</p><Link className="primary-action" href="/docs">返回使用指南 →</Link></main>;
}
