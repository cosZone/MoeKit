# preview.12 发布验证记录

[发布运行](https://github.com/cosZone/MoeKit/actions/runs/37510296062)采用源码 `fa630c57dd87862597874d5ba459453beac95e60`，run17／attempt1，build2.0.12；构建、签名、发布均通过。

- `signed-notes.md` 保留签名时的完整原始 Markdown；其 unreleased 状态是发布前快照
- `original-release-body.md` 保留工作流最初生成的正文；`concise-release-body.md` 是之后仅替换展示正文的简短版本
- `provenance.json` 记录原始文件摘要、五份公开资产及 feed 提交关系；旧哈希不用于校验修改后的展示说明

五份公开资产、完整 ZIP 内容与构建来源已经交叉核验。固定公钥下的 ZIP／feed Ed25519 验证通过，修改字节的对照被拒绝。公开 feed 与 Release 资产及 Git blob 相同，updates 保留 preview.11 的父提交。

原生签名步骤验证九份代码的双架构、开发签名／预期身份及 DMG／ZIP 内 App 一致性。补充检查通过18份 CMS 数学签名、2,720个代码页、特殊槽与篡改拒绝；它不替代 macOS 证书链信任、完整资源规则或嵌套代码语义。公开签名证书 SHA-256 为 `3687c2aecf25ed3226886d4c08b0ef2f83c354f2c37424022a821e5cf727d778`。

同源码的 Native、Docs 和双架构 Sparkle 检查均通过；20个合成更新场景验证安装／重启、偏好保留和拒绝／取消边界。合成测试不代表真实用户已经完成一次生产更新。

仍使用 Apple Development 签名、未公证。完整窗口、键盘／VoiceOver、多显示器／Spaces、Docker Desktop、真实远端 TLS／Keychain 交互和实际安装更新仍需验收。没有清理真实用户数据或更改私钥／权限设置。
