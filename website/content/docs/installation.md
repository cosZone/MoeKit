---
title: 安装与预览
description: 先核对来源和版本，再了解 macOS 的安全提示。
---

## 系统要求

- 运行目标：macOS 15 或更高版本
- 原生应用：SwiftUI / AppKit
- 手动预览与签名发布流程会检查 arm64 和 x86_64 架构；包含两个架构不等于都已完成实机验收

## 获取可用产物

当前已交付 [0.1.0-preview.6 开发签名预览](https://github.com/cosZone/MoeKit/releases/tag/v0.1.0-preview.6)，提供 DMG 与 ZIP，包内是同一份 universal Release App，并附校验和与构建信息。本版接入逐次确认的官方固定版本 Mole 目录分析、工具准备与边界加固；使用 Apple Development 签名，未公证。文档网站独立构建，不是安装包组件。

先查看 [GitHub Releases](https://github.com/cosZone/MoeKit/releases)。只有实际发布页中附带的文件才是已交付版本；文档中的版本计划或示例号不构成下载承诺。

维护者也可从 [GitHub Actions](https://github.com/cosZone/MoeKit/actions) 手动运行 **Preview app artifact**，下载包含应用、源码提交与校验信息的预览产物。Actions 产物有保留期限，可能需要登录 GitHub。

推荐下载 Release 中的 DMG，核对来源与校验和后打开，将 `MoeKit.app` 拖到 `Applications` 快捷方式，再从安装位置启动。ZIP 可直接解压取得同一份 App。两种包均同时支持 Apple Silicon 与 Intel，无需按芯片选包。

如果使用 Actions 手动预览，解开外层下载包后，内层 ZIP 才包含 `MoeKit.app`；不要把 Actions 的外层包与 Release 安装包混淆。

只下载 DMG 时，在文件所在目录执行，并将结果与 `SHA256SUMS.txt` 中的同名条目对照：

```sh
shasum -a 256 MoeKit-v0.1.0-preview.6-macOS.dmg
```

如果 DMG、ZIP、`BUILD_INFO.json` 和校验和文件全部已下载到同一目录，可一次检查全部：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

校验和验证文件是否与发布者提供的字节一致，不能替代对发布来源的信任判断。

## 第一次打开

健康且为空的真实项目列表首次启动时会显示上手引导，可以先看示例、进入项目工作区或进入进程与端口页。进入页面不会自动扫描；选择自己的文件夹或点击 Start scan / Refresh 后才开始对应读取。

引导可跳过，并可从 **Help → Getting started** 或 **Settings → General → Getting started** 重新打开。已有项目、列表读取错误或显式 Demo 启动时不会自动弹出。跳过只额外保存本地引导版本号，不会清空项目列表。

## 使用本版的 Mole 分析

MoeKit 不附带或自动安装 Mole。先确认已有分析器与 [官方 V1.57.0 发布](https://github.com/tw93/Mole/releases/tag/V1.57.0) 的原始二进制匹配，再在 **Tools → Mole → Space → 使用 Mole 分析…** 选择直接分析器和一个目录，复查计划并确认。官方脚本安装的常见位置是 `~/.config/mole/bin/analyze-go`；不能选择 `mo` 包装脚本。

本版不接受 Homebrew、自编译或其他版本。工具准备中的“已找到 · 未验证”与复制安装命令不能替代分析校验。遇到隔离标记、内容变化或不匹配文件时会拒绝运行，不移除隔离标记或绕过 Gatekeeper。

分析使用普通用户权限，不是 OS 沙箱；确认会说明私有副本、缓存和临时目录写入。不会修改或删除所选内容，尚未接入可执行的清理操作。完整范围与取消说明见 [Mole 空间分析与报告](/docs/mole)。

## 签名和公证是不同的事

| 产物类型 | 签名 | Apple 公证 | 适用范围 |
| --- | --- | --- | --- |
| Actions 手动预览 | ad-hoc | 无 | 开发构建与检查 |
| 开发签名预览流程 | Apple Development | 无 | 受控测试与作者试用 |
| 正式对外分发 | 尚未完成 | 尚未完成 | 不承诺当前预览满足正式分发条件 |

**Apple Development 签名不是 Developer ID 分发签名。** 即使签名校验通过，Gatekeeper 仍可能阻止打开；这不意味着应用已获 Apple 审核。请按 [Apple 官方安全说明](https://support.apple.com/en-us/102445) 判断来源。遇到阻止时保留完整提示并报告问题，不要关闭系统保护或修改应用来规避检查。

不要把证书、P12、密码、私钥或其他凭据贴进 Issue。报告安装问题时提供 macOS 版本、芯片架构、版本号、来源链接和脱敏后的提示即可。

## 从源码运行

需要 macOS、Xcode 16.4 和 [Mise](https://mise.jdx.dev/getting-started.html)。在仓库根目录运行：

```sh
mise install
mise exec -- tuist generate --no-open
xcodebuild -workspace MoeKit.xcworkspace -scheme MoeKit \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
open DerivedData/Build/Products/Debug/MoeKit.app
```

这是本地开发用 ad-hoc 构建，不会完成正式分发签名。`Package.swift` 仅管理 Tuist 的 SPM 依赖；不使用 `swift run` 启动此应用。

更详细的维护者流程见仓库中的 [构建说明](https://github.com/cosZone/MoeKit/blob/main/Documentation/Build-and-preview.md) 和 [开发签名预览](https://github.com/cosZone/MoeKit/blob/main/Documentation/Signed-preview-release.md)。
