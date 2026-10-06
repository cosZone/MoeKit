---
title: "0.1.0-preview.12"
version: "0.1.0-preview.12"
description: "Mole 更易上手，新增 AI worktree 收尾，界面和菜单栏更简洁。"
status: unreleased
---

## 更新

- **Mole 更易上手**：自动检测兼容安装，缺少时提供分步准备与重新检测
- **AI worktree 收尾**：确认本地合入，按需另行确认推送，核验后再单独决定退役；退役保留恢复数据
- **界面更简洁**：精简重复说明，About 显示完整的 preview 版本
- **菜单栏焕新**：幽灵工具箱图标、快捷面板和任务状态提示，支持“减少动态效果”

## 使用前

Git 本地合入目前仅支持 fast-forward；推送与退役分别确认，不自动重试不确定的推送。真实远端凭据交互仍需实机验收。

macOS 15+，Apple Silicon / Intel。使用 Apple Development 签名、未公证；preview.9 及更早版本需先手动安装一次。

[Mole 准备指南](https://github.com/cosZone/MoeKit/blob/72f9f1f91f52d6c19f2177615780ecd0376fe6d9/Documentation/Mole-beginner-setup.md) · [AI worktree 支持范围](https://github.com/cosZone/MoeKit/blob/72f9f1f91f52d6c19f2177615780ecd0376fe6d9/Documentation/Git-worktree-finish.md)
