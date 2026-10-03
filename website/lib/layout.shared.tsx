import Image from 'next/image';
import type { BaseLayoutProps } from 'fumadocs-ui/layouts/shared';

export function baseOptions(): BaseLayoutProps {
  return {
    nav: { title: <><Image src="/icon.svg" width={28} height={28} alt="" className="rounded-lg" /><span className="brand-name">MoeKit</span><span className="brand-label">文档</span></> },
    githubUrl: 'https://github.com/cosZone/MoeKit',
    links: [
      { text: '使用指南', url: '/docs', active: 'nested-url' },
      { text: '更新日志', url: '/changelog', active: 'nested-url' },
    ],
  };
}
