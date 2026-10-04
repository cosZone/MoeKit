# 文档站搜索与依赖维护

## 搜索接口边界

`GET /api/search` 由应用自己的处理器验证，再调用 Fumadocs 搜索：

- `query` 可省略或为空；空白查询返回 `[]`。长度上限 256 个 UTF-16 code units（去掉空白前计数）
- `mode` 只接受省略或 `full`，这是 Fumadocs 对外 API 的全词搜索名称。本站未配置向量索引或向量服务
- `limit` 为十进制整数 `1`–`60`，省略时为 `60`；不接受符号、前导零、小数、指数或空值
- 所有页面的索引语言为 `zh-CN`，同一索引支持中文和英文查询。`locale` 只接受省略、空值或 `zh-CN`
- 当前没有标签过滤器，`tag` 只接受省略或空值
- 不接受重复参数或未支持的参数；完整请求 URL 上限为 4096 个 UTF-16 code units

预期的无效输入统一返回 HTTP 400 和 `{"error":"invalid_search_request"}`，不回显输入，也不调用搜索引擎。上游 HTTP 服务或反向代理可能先拒绝更大的请求。此处理器不替代部署层的请求大小、速率及资源限制。

`npm test` 验证处理器只传递明确构造的全词选项；`npm run smoke` 对实际生产服务验证中文、英文、空查询、边界和无效输入，以及错误后的健康与搜索可用性。Docs CI 对构建出的非 root 容器执行同一 HTTP 检查。

## 临时开发依赖例外

2026-10-04 核对 [GHSA-vfj7-8cjw-p6xm / CVE-2026-93687](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)：受影响的 `braces <=3.0.3` 尚无公告列出的已修复版本；npm registry 当前 latest 为 `3.0.3`。

锁文件中的已审查链为：

`eslint-config-next@16.3.8 → @next/eslint-plugin-next@16.3.8 → fast-glob@3.3.1 → micromatch@4.0.8 → braces@3.0.3`

五项 npm audit 记录来自同一个底层公告，以上节点均为 `dev: true`。当前生产依赖审计无记录，standalone 产物不包含这条 lint 开发链；未确认网站请求能到达该 braces 路径。这个例外不表示漏洞已修复，也不意味着开发依赖可以永久忽略。

`npm run audit:dependencies` 在 Docs CI 中输出完整审计并明确警告这个已知问题；任何生产依赖公告都会失败。例外只允许上述精确锁定版本、位置、开发属性、依赖链和公告 URL；新增公告、暴露范围或格式变化都会失败，需要重新审查。网络或审计错误也不会被当作无漏洞结果。

维护动作：跟踪公告及上游版本，存在兼容修复后更新锁文件、移除此例外，重新运行依赖审计、`npm run check`、生产 HTTP smoke，并复核 standalone 依赖。不要执行 `npm audit fix --force` 给出的 Next ESLint 14 降级，也不要用未验证 override 隐藏公告。Next 与 eslint-config-next 保持当前同版本基线。

本改动不配置 Dokploy、域名、TLS、GitHub 安全设置、密钥或部署，也不声称完成远程拒绝服务测试。
