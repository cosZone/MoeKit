---
title: 开发与文档维护
description: 原生应用和文档网站共用仓库，各自构建与测试。
---

## 仓库分工

| 目录 | 用途 |
| --- | --- |
| `Sources/`、`Tests/`、`Project.swift` | macOS 原生应用与测试 |
| `Documentation/` | 深入架构、签名与原生验收记录 |
| `website/` | Fumadocs / Next.js 文档网站 |
| `website/content/docs/` | 使用文档，Markdown 或 MDX |
| `website/content/changelog/` | 每个版本一份普通 `.md` |

两边没有根级 npm workspace 或共享运行时依赖。网站不会改变 Swift、Tuist 或签名流程的执行环境。

## 本地预览网站

需要 Node.js 22 或更高版本。进入 `website` 后：

```sh
npm ci
npm run dev
```

打开 `http://localhost:3000`。完整检查：

```sh
npm run check
npm run start
# 在另一个终端的 website 目录：
npm run smoke
```

`check` 包括 ESLint、MDX/路由生成、TypeScript、内容规则测试与生产构建。`smoke` 检查线上服务的页面、404、中文搜索和健康端点；默认只访问本机 3000 端口。

## 写一份版本记录

以版本号命名文件，例如 `content/changelog/0.1.0-preview.1.md`。内容使用普通 Markdown，不写 JSX 或 import。

```yaml
---
title: 0.1.0-preview.1
version: 0.1.0-preview.1
description: 原生工作台与只读工具的首个开发预览。
status: unreleased
---
```

准备版本时使用 `unreleased`，不填写虚构发布日期、发布地址或已交付的源码 SHA。只有确认 Release 已发布、产物可取且来源一致后，才能更新为 `prerelease` 或 `released`，并补齐 `date`（带引号的 UTC 日期，例如 `"2026-10-03"`）、`sourceCommit`、`releaseUrl`。

未确定下一版本号的工作暂存在 `content/changelog/unreleased.md`；已发布版本仍然一版一份文件。新增版本文件会自动出现在更新日志页，无需手工复制到页面代码。已经发布的版本记录尽量保持稳定；错误修订应说明原因。

## 自动化与验证

Native CI 继续负责 macOS 构建与 Swift 测试。独立 Docs CI 只在网站或其工作流变化时运行，不接触签名 secrets，也不发布站点或镜像。

网站检查不能代替原生验收，原生 CI 通过也不能证明网站部署正常。关于来源和限制，请同时阅读 [功能状态](/docs/status)。

技术参考：[Fumadocs](https://www.fumadocs.dev/docs)、[Next.js 自托管](https://nextjs.org/docs/app/guides/self-hosting)。
