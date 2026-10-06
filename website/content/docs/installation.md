---
title: 安装与预览
description: 先核对来源和版本，再了解 macOS 的安全提示。
---

## 系统要求

- 运行目标：macOS 15 或更高版本
- 原生应用：SwiftUI / AppKit
- 手动预览与签名发布流程会检查 arm64 和 x86_64 架构；包含两个架构不等于都已完成实机验收

## 获取可用产物

当前已交付 [0.1.0-preview.10 开发签名预览](https://github.com/cosZone/MoeKit/releases/tag/v0.1.0-preview.10)：[下载 DMG](https://github.com/cosZone/MoeKit/releases/download/v0.1.0-preview.10/MoeKit-v0.1.0-preview.10-macOS.dmg) · [下载 ZIP](https://github.com/cosZone/MoeKit/releases/download/v0.1.0-preview.10/MoeKit-v0.1.0-preview.10-macOS.zip)。包内是同一份 universal Release App，并附校验和、构建信息与已签名 appcast。本版首次接入 Sparkle 签名更新，保留此前 Git、Mole、缓存、精确进程与 Downloads 磁盘映像工作流。使用 Apple Development 签名，未公证。精确测试与公开下载验证见 [版本记录](/changelog/0.1.0-preview.10)；文档网站独立构建，不是安装包组件。

**preview.9 及更早版本仍需手动下载并安装本版一次。** 旧版没有自动安装器，不能自行安装 Sparkle；请先完成当前操作并退出旧应用，再按下述正常安装步骤替换应用。

先查看 [GitHub Releases](https://github.com/cosZone/MoeKit/releases)。只有实际发布页中附带的文件才是已交付版本；文档中的版本计划或示例号不构成下载承诺。

维护者也可从 [GitHub Actions](https://github.com/cosZone/MoeKit/actions) 手动运行 **Preview app artifact**，下载包含应用、源码提交与校验信息的预览产物。Actions 产物有保留期限，可能需要登录 GitHub。

推荐下载 Release 中的 DMG，核对来源与校验和后打开，将 `MoeKit.app` 拖到 `Applications` 快捷方式，再从安装位置启动。ZIP 可直接解压取得同一份 App。两种包均同时支持 Apple Silicon 与 Intel，无需按芯片选包。

如果使用 Actions 手动预览，解开外层下载包后，内层 ZIP 才包含 `MoeKit.app`；不要把 Actions 的外层包与 Release 安装包混淆。

只下载 DMG 时，在文件所在目录执行，并将结果与 `SHA256SUMS.txt` 中的同名条目对照：

```sh
shasum -a 256 MoeKit-v0.1.0-preview.10-macOS.dmg
```

如果 DMG、ZIP、`BUILD_INFO.json`、`appcast.xml` 和校验和五个文件全部已下载到同一目录，可一次检查全部：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

校验和验证文件是否与发布者提供的字节一致，不能替代对发布来源的信任判断。

## 第一次打开

健康且为空的真实项目列表首次启动时会显示上手引导，可以先看示例、进入项目工作区或进入进程与端口页。进入页面不会自动扫描；选择自己的文件夹或点击 Start scan / Refresh 后才开始对应读取。

引导可跳过，并可从 **Help → Getting started** 或 **Settings → General → Getting started** 重新打开。已有项目、列表读取错误或显式 Demo 启动时不会自动弹出。跳过只额外保存本地引导版本号，不会清空项目列表。

## 图标、重开与应用更新

Settings → App icons 分别设置 Dock 与菜单栏图标。两者均隐藏时，可从 Finder 或 Spotlight 再次打开 MoeKit 恢复工作区；关闭窗口不等于退出应用，各项任务仍遵守自身取消规则。

安装 preview.10 后，应用菜单、菜单栏与 Settings → Updates 共享 Sparkle 更新界面。标准第二次启动提示询问后台检查；「自动下载并安装更新」默认关闭，可另行开启，自动安装通常等到退出应用。检查／下载偏好和预览渠道选择会保存；正在执行原生修改／恢复、Git 整理、进程停止或 Mole 分析时会拒绝为更新退出。

请求可能发送应用版本，GitHub 可见连接 IP，不发送项目／任务内容或系统画像。更新源和 ZIP 都要求签名，ZIP 在解压前验证；配置不可用时仍可主动查看 GitHub 手动版本检查，签名失败不自动退回未签名安装。实际用户生产安装的后续更新与权限迁移仍需验收。详细行为见 [preview.10 说明](/changelog/0.1.0-preview.10)。

Git 整理需要受支持的本地仓库和固定位置已安装的 Apple 签名 Git；工具缺失或不支持时拒绝，不自动下载安装。每个目标需检查与独立确认，移动到恢复目录不释放空间。使用与恢复限制见 [项目管理](/docs/projects)。

## 使用本版的 Mole 分析

MoeKit 不附带或自动安装 Mole。先确认已有分析器与 [官方 V1.57.0 发布](https://github.com/tw93/Mole/releases/tag/V1.57.0) 的原始二进制匹配，再在 **Tools → Mole → Space → 使用 Mole 分析…** 选择直接分析器和一个目录，复查计划并确认。官方脚本安装的常见位置是 `~/.config/mole/bin/analyze-go`；不能选择 `mo` 包装脚本。

本版不接受 Homebrew、自编译或其他版本。工具准备中的“已找到 · 未验证”与复制安装命令不能替代分析校验。遇到隔离标记、内容变化或不匹配文件时会拒绝运行，不移除隔离标记或绕过 Gatekeeper。

分析使用普通用户权限，不是 OS 沙箱；确认会说明私有副本、缓存和临时目录写入。Mole 分析本身不会修改或删除所选内容。preview.7 另有独立复查并确认的原生文件操作：从当前真实 Downloads 分析中选择一个受支持的直属 `.dmg`，移到废纸篓或凭记录另行确认恢复；不覆盖、不清空废纸篓，不提供广域 Mole 清理。

使用该操作前，先将 App 安装到 Applications，并只自行推出自己打开的磁盘映像；系统管理的映像不要触碰。首版要求完整空映像清单，系统映像存在时可能持续不可用。完整范围、取消与恢复限制见 [Mole 空间分析与报告](/docs/mole)。

## 使用本版的缓存与进程操作

缓存操作从 **Tools → Mole → Cleanup** 主动检查开始，每批最多 16 项。支持用户缓存直属目录，或当前用户主目录内带有效 `CACHEDIR.TAG` 的受支持直属候选目录；完整清单、项目保护与本地 APFS 检查通过后，仍须确认相关工作已停止且内容可重新生成，才能移入原生废纸篓。恢复不覆盖；永久删除只针对本应用已完成的缓存记录，另行确认且不可恢复。永久删除也不保证立即等量释放物理空间。详见 [Mole 页面](/docs/mole)。

**Tools → Processes & Ports** 支持主动扫描后复查 1–16 个精确、非受保护的当前用户身份，单次确认 SIGTERM；仍运行的同一身份才可重新复查并确认 SIGKILL。浏览器／共享服务等仍受保护，不按名称、组或父子关系扩展选择。发送信号可能影响未保存工作和依赖任务；详见 [进程与端口](/docs/processes)。

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
mise exec -- tuist install
mise exec -- tuist generate --no-open
xcodebuild -workspace MoeKit.xcworkspace -scheme MoeKit \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
open DerivedData/Build/Products/Debug/MoeKit.app
```

这是本地开发用 ad-hoc 构建，不会完成正式分发签名。`Package.swift` 仅管理 Tuist 的 SPM 依赖；不使用 `swift run` 启动此应用。

更详细的维护者流程见仓库中的 [构建说明](https://github.com/cosZone/MoeKit/blob/main/Documentation/Build-and-preview.md) 和 [开发签名预览](https://github.com/cosZone/MoeKit/blob/main/Documentation/Signed-preview-release.md)。
