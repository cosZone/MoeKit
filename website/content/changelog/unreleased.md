---
title: 尚未发布
version: unreleased
description: 首个预览发布之后的源码与文档进展，尚未进入已发布安装包。
status: unreleased
---

## 后续工作

[0.1.0-preview.3](/changelog/0.1.0-preview.3) 已交付多目录项目与 worktree 复查、进程筛选和工作区可靠性改进，提供 DMG 与 ZIP。后续应用改动只有在对应版本实际发布并核实后，才会标记为已交付。

[0.1.0-preview.4](/changelog/0.1.0-preview.4) 正在整理文件读取与项目列表保存的可靠性修复，尚未发布；这些修复不计入 preview.3 安装包。

预览发布源码固定后，仓库另外补充了 8 张中文测试自有视图的渲染与校验检查，已检查对应图片；该增量仅涉及测试、CI 和验收说明，没有改变发布 App 的生产代码或翻译。它不是 preview.3 发布任务的一部分，也不等于中文完整窗口交互或 VoiceOver 已验收。

文档网站源码、Fumadocs 中文指南、站内搜索、Docker 镜像与 Dokploy 配置指南已合入仓库，但公开站点部署和生产域名尚未完成。网站独立部署，不是 App 安装包的一部分。

原生视觉、VoiceOver、双架构实机体验与真实进程权限覆盖仍需手动验收。后续版本以独立 Markdown 记录保存实际交付内容和验证范围。
