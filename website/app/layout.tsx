import './global.css';
import { translations } from '@/lib/translations';
import { RootProvider } from 'fumadocs-ui/provider/next';
import type { Metadata } from 'next';
import type { ReactNode } from 'react';

export const metadata: Metadata = {
  title: { default: 'MoeKit · 给常用工具一个家', template: '%s · MoeKit' },
  description: 'MoeKit 是 macOS 原生个人 CLI 工具箱。了解项目发现、只读工具、预览安装与版本进展。',
  icons: { icon: '/icon.svg', apple: '/apple-icon.png' },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="zh-CN" suppressHydrationWarning>
      <body className="flex min-h-screen flex-col">
        <RootProvider i18n={{ locale: 'zh-CN', translations }}>{children}</RootProvider>
      </body>
    </html>
  );
}
