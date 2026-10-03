---
title: 部署到 Dokploy
description: 同仓库、独立 Docker 构建，域名和上线由你决定。
---

## 部署形态

`website/Dockerfile` 生成 Next.js standalone 生产镜像：构建与运行分阶段，运行时使用非 root 用户，监听 `0.0.0.0:3000`。`/health` 返回 JSON 健康状态。

不需要数据库、签名证书、API key 或持久卷。网站没有与 Mac 通信的服务。不要把原生签名 secrets 传给网站构建。

## 先在本地验证容器

在仓库根目录运行：

```sh
docker build -f website/Dockerfile -t moekit-docs:local website
docker run --rm -p 127.0.0.1:3000:3000 moekit-docs:local
```

另开终端检查：

```sh
curl --fail http://localhost:3000/health
cd website
npm run smoke
```

构建上下文是 `website`，不是整个原生仓库。这个边界也让应用源码、签名产物与本地凭据不会被顺手复制进站点镜像。

## Dokploy Application 配置

在你的 Dokploy 实例中创建 Application，选择 GitHub 或 Git 来源并指向 `cosZone/MoeKit`。选择已经审阅和合并的网站提交。

以仓库根目录为基础配置：

| 字段 | 值 |
| --- | --- |
| Repository | `https://github.com/cosZone/MoeKit` |
| Branch | `main`，或你选定的已审阅分支 |
| Build Type | Dockerfile |
| Dockerfile Path | `website/Dockerfile` |
| Docker Context Path | `website` |
| Docker Build Stage | `runner`，或留空使用最终阶段 |
| 容器端口 | `3000` |
| 健康检查路径 | `/health` |

字段基于 [Dokploy Dockerfile 构建说明](https://docs.dokploy.com/docs/core/applications/build-type)。不同版本若先单独指定项目 Build Path，请检查实际构建命令：Dockerfile 与 context 必须最终解析到同一个 `website` 目录，避免重复成 `website/website`。

Dockerfile 已设置 `NODE_ENV=production`、`PORT=3000`、`HOSTNAME=0.0.0.0` 和禁用 Next.js telemetry。无需额外 Start Command；保留镜像的 `node server.js`。

## 域名、TLS 与上线

在 Dokploy 的 Domains 为自己的域名配置端口 3000，按其文档设置 DNS 与 HTTPS。项目没有预设生产域名，因此页面不生成猜测的 canonical URL 或 sitemap。域名确定后再补充 SEO 地址配置。

这里提供的是部署准备，不表示已经上线。首次发布时检查首页、深层文档、更新日志、中文搜索、手机导航以及 `/health`。文档与版本记录都在构建时处理，改动后需要重新构建镜像。

## 生产维护

- 为构建预留 CPU、内存和磁盘；低配服务器可改为在独立构建机生成镜像
- 不把源代码目录或 `node_modules` 挂载进生产容器
- 保留上一可用镜像或提交，检查失败时回滚
- 容器自带健康检查；如启用 Swarm 更新回滚，在 Dokploy 中分别配置健康与更新策略
- 搜索请求含用户查询词，按自己的隐私要求配置代理日志与保留时间

可选的本地 Compose 文件是 `website/compose.yaml`，默认只绑定本机。Dokploy 推荐按 Application 流程配置域名，不要直接复制本地端口绑定作为公网设置。

参考：[Fumadocs Docker 部署](https://www.fumadocs.dev/docs/deploying)、[Next.js standalone](https://nextjs.org/docs/app/api-reference/config/next-config-js/output)、[Dokploy 生产指南](https://docs.dokploy.com/docs/core/applications/going-production)。
