---
title: 安装与预览
description: 先核对来源和版本，再了解 macOS 的安全提示。
---

## 系统要求

- 运行目标：macOS 15 或更高版本
- 原生应用：SwiftUI / AppKit
- 手动预览与签名发布流程会检查 arm64 和 x86_64 架构；包含两个架构不等于都已完成实机验收

## 获取可用产物

当前已交付 [0.1.0-preview.1 开发签名预览](https://github.com/cosZone/MoeKit/releases/tag/v0.1.0-preview.1)，包含 universal Release 应用、校验和与构建信息。它使用 Apple Development 签名，未公证；不包含后续 About 窗口与文档网站改动。

先查看 [GitHub Releases](https://github.com/cosZone/MoeKit/releases)。只有实际发布页中附带的文件才是已交付版本；文档中的版本计划或示例号不构成下载承诺。

维护者也可从 [GitHub Actions](https://github.com/cosZone/MoeKit/actions) 手动运行 **Preview app artifact**，下载包含应用、源码提交与校验信息的预览产物。Actions 产物有保留期限，可能需要登录 GitHub。

解开 Actions 的外层下载包后，内层 ZIP 才包含 `MoeKit.app`。签名预览的 Release ZIP 直接包含应用。把应用放到你自己的 Applications 目录前，先核对版本、构建记录及校验和。

在校验和文件与对应 ZIP 所在目录执行：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

校验和验证文件是否与发布者提供的字节一致，不能替代对发布来源的信任判断。

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
