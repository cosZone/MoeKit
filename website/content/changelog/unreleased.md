---
title: 尚未发布
version: unreleased
description: 已交付版本之外的后续工作与验证边界。
status: unreleased
---

## 最近交付

[0.1.0-preview.8](/changelog/0.1.0-preview.8) 已交付逐次确认的精确进程停止，以及原生多缓存废纸篓、原路径恢复和依据操作记录另行确认的缓存永久删除，提供已核实的 DMG 与 ZIP。进程停止不扩展到浏览器／共享服务或无头会话归属；缓存位置与标记不能代替使用者确认，永久删除不可恢复且不保证物理空间立即回收。安装限制、精确源码、构建及下载验证见该版本记录。

## 已合入源码，尚未发布

菜单栏入口、Dock／菜单栏图标设置与手动检查 GitHub 新版本已随 [PR #44](https://github.com/cosZone/MoeKit/pull/44) 合入当前源码，尚未包含在 preview.8 安装包。检查更新由用户主动触发，下载后仍需手动安装；不等同于 Sparkle 自动更新。实现与限制见 [更新与应用入口](https://github.com/cosZone/MoeKit/blob/41547901a3fde532314939af58d7506b74a7dd0e/Documentation/Updates-and-app-icons.md)。

## 后续工作

广域 Mole 清理、卸载、维护、项目删除、任意进程停止和真实 Git status 仍未启用。实验性 Git status／Git 清理、菜单栏与 Dock 改进、手动更新入口不包含在 preview.8 安装包，Sparkle 自动更新仍未启用。后续应用改动只有在对应版本实际发布并核实后，才会标记为已交付。

中文测试自有视图、完整优化 Release 测试与定向内存检查已加入 CI。合成视图和自动检查的范围见对应版本记录，不代表完整窗口交互、键盘、VoiceOver 或真实 Mac 权限覆盖已验收。

文档网站源码、Fumadocs 中文指南、站内搜索、Docker 镜像与 Dokploy 配置指南已合入仓库，但公开站点部署和生产域名尚未完成。网站独立部署，不是 App 安装包的一部分。

原生视觉、VoiceOver、双架构实机体验与真实进程权限覆盖仍需手动验收。后续版本以独立 Markdown 记录保存实际交付内容和验证范围。
