# MoeKit 文档站

同仓库独立的 Fumadocs + Next.js 网站；不运行 Swift，不接触原生签名 secrets。Node.js 22+（Docker / CI 固定 Node.js 24.19.0）。

```sh
cd website
npm ci
npm run dev
```

生产检查：`npm run check`。生产预览：`npm run start`；另开终端运行 `npm run smoke`。所有直接依赖与锁文件均固定版本，升级后重新检查。

- `content/docs/*.md`：中文使用文档，侧栏顺序由 `meta.json` 管理
- `content/changelog/<version>.md`：每版一份普通 Markdown，自动生成更新列表；未定版本的后续变更暂存在 `unreleased.md`，不允许 JSX/import
- `source.config.ts`：文档及版本记录 schema
- `scripts/content.test.mjs`：内部链接、版本文件、发布元数据规则
- `scripts/smoke.mjs`：生产 HTTP 路由、404、健康端点、中英文搜索

## Docker / Dokploy

在仓库根目录运行：

```sh
docker build -f website/Dockerfile -t moekit-docs:local website
docker run --rm -p 127.0.0.1:3000:3000 moekit-docs:local
```

Dokploy 使用 Application → Dockerfile：Repository `cosZone/MoeKit`，Dockerfile Path `website/Dockerfile`，Docker Context Path `website`，最终 stage `runner`，端口 `3000`，健康路径 `/health`。如额外配置项目 Build Path，确保最终 Dockerfile/context 不重复 `website`。域名和 TLS 由部署者设置，不包含自动部署、付费服务或域名配置。

详见 [部署指南](content/docs/deployment.md) 和 [Dokploy 官方字段说明](https://docs.dokploy.com/docs/core/applications/build-type)。容器不需要持久卷或 secrets，使用非 root 用户运行 standalone 产物。不要在生产挂载开发源码。`compose.yaml` 仅供本机预览。

`/api/search` 在本站服务器处理请求（含查询词）；反向代理的日志策略由部署者决定。没有外部字体、分析 SDK、登录、数据库或云搜索服务。未配置生产域名前不生成猜测的 canonical 或 sitemap。

## 发布记录规则

准备中的版本：`status: unreleased`，无发布日期、最终源码 SHA 或发布 URL。只有确认真实 GitHub Release 与产物后才能标记 `prerelease` / `released`，并补充带引号的 YYYY-MM-DD UTC 日期、完整 `sourceCommit` 和该版本的 `releaseUrl`。内容检查会验证字段一致性，但不能代替实际发布验证。

技术参考：[Fumadocs Next.js](https://www.fumadocs.dev/docs/manual-installation/next)、[Fumadocs Docker](https://www.fumadocs.dev/docs/deploying)、[Next.js standalone](https://nextjs.org/docs/app/api-reference/config/next-config-js/output)。
