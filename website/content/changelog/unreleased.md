---
title: 尚未发布
version: unreleased
description: 已交付版本之外的后续工作与验证边界。
status: unreleased
---

## 正在准备：preview.11

[0.1.0-preview.11](/changelog/0.1.0-preview.11) 的完整版本说明已准备，源码新增 Cleanup → Trash / Docker：个人本地 APFS 废纸篓的所选永久删除／输入 `EMPTY` 后清空已验证快照，以及精确 Docker 镜像／停止容器删除与另行确认的 daemon-wide 未使用构建缓存清理。运行容器、卷和不支持对象保持保护；取消、迟到或不确定结果不冒充成功。

这些功能已合入源码，**尚未发布为 preview.11 安装包**。当前可下载版本仍是 preview.10；只有实际发布、核对产物与签名后才会标记交付。AI worktree 完工流程与 AI 专用无头浏览器归属清理不在本次发布范围内。支持范围、不可恢复确认和自动化／实机验证界线见独立版本说明。

## 最近交付

[0.1.0-preview.10](/changelog/0.1.0-preview.10) 已交付首个 Sparkle 签名更新版本：固定更新源与公钥、后台检查、可选的自动下载安装，以及独立预览渠道设置。五份公开资产、八份代码的双架构签名和首个 signed feed 已核实；从 preview.9 及更早版本仍需先手动安装一次。

此前的 Git 整理、应用入口、精确进程停止、原生缓存工作流、Mole 分析与单个 Downloads 磁盘映像操作继续保留各自边界。preview.9 仅有手动版本检查，历史版本说明与资产保持原样。完整证据、安装限制与人工验收范围见 preview.10 记录。

## 后续工作

真实用户安装的生产签名 App 后续更新、Gatekeeper 和隐私授权迁移仍需验收；独立合成 fixture 的安装／重启不替代这些检查。当前 active feed 仅含最新一项 preview，正式版发布与多条目／独立频道策略仍需另行实现和验证。Developer ID 分发与 Apple 公证尚未交付。

广域 Mole 清理、卸载、维护、任意项目删除、任意进程停止、AI 专用无头浏览器归属识别和通用实时 Git status 仍未启用。后续应用改动只有在对应版本实际发布并核实后，才会标记为已交付。

中文测试自有视图、完整优化 Release 测试与定向内存检查已加入 CI。合成视图和自动检查的范围见对应版本记录，不代表完整窗口交互、键盘、VoiceOver 或真实 Mac 权限覆盖已验收。

文档网站源码、Fumadocs 中文指南、站内搜索、Docker 镜像与 Dokploy 配置指南已合入仓库，但公开站点部署和生产域名尚未完成。网站独立部署，不是 App 安装包的一部分。

原生视觉、VoiceOver、双架构实机体验与真实进程权限覆盖仍需手动验收。后续版本以独立 Markdown 记录保存实际交付内容和验证范围。

## AI worktree 收尾（后续源码）

新增从真实 Git 证据出发的收尾流程：干净 linked worktree fast-forward 到现有本地分支，包含在主 worktree 检出的 main；复核后可另行批准精确 HTTPS 远端 non-force push，并独立读取远端 OID 确认结果，最后单独检查和确认退役。原目标内容/index/ref 保留；不运行仓库脚本或测试，不将 AI 完成消息当作证据，不自动 stash/reset/rebase/force push。未知远端结果保留工作树，提供只读复查。

这是未发布源码工作，不属于 preview.10 或 preview.11 的发布范围。macOS 编译、合成原生 fixture、完整 GUI 与真实凭据体验的验证范围应分别记录；源码合入不代表安装包或真实用户操作已经验收。设计与限制见仓库 Documentation/Git-worktree-finish.md。
