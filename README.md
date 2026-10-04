# MoeKit

面向 macOS 的个人 CLI 工具箱：把项目、工具和任务放进一个原生工作台。Mole 是首个内置模块，整体架构为更多个人常用工具保留扩展位置。

Swift 6 · SwiftUI / AppKit · macOS 15+ · Tuist 4.148.3 · SPM

## 当前预览

已经写入源码：
- **Projects**：原生表格、搜索与排序、项目详情 inspector、置顶项目、Finder 定位；多根目录只读发现 Git 项目，复查筛选后导入/刷新；验证 worktree 关系后分组，展示带时间的分支/锁元数据和不可执行的清理安全复查
- **Tools**：Mole 的 Space / Clean / Apps / Maintenance / Status 工作区；Space 可导入 Mole analyze JSON，也可选择已安装的官方 V1.57.0 直接分析器与单个文件夹，复查确认后实际分析；Processes & Ports 可由用户主动读取当前用户进程和 TCP 监听端口，按工作目录展示项目关联
- **Processes & Ports**：原生密集表格、身份与关联证据、部分读取提示、项目相关进程入口，以及不可执行的精确选择停止计划预览；不读取命令参数/环境变量，不自动扫描或发送进程信号
- **工具准备**：从 Settings 或 Mole 打开，主动检查固定常见位置或自选文件的元数据，区分未检查、该路径未找到、找到但未验证、不支持与无法读取；提供官方安装说明和复制命令，不安装、不探测版本、不运行 CLI
- **Tasks**：本次会话的发现任务、取消、状态与底部结果详情；可展开 Diagnostics
- 独立 Demo 开关与明确示例标识；正常启动无虚构项目、运行结果或磁盘测量
- 可跳过、可重开的上手引导：项目整理、进程查看或示例体验；先说明范围，再由用户主动选择文件夹或开始扫描
- 原生 NavigationSplitView、Table、工具栏与 SF Symbols；自定义应用图标

尚未实现：任意 CLI 执行、停止/强制停止其他进程、清理、卸载、维护、实时系统指标、提权、第三方插件加载及持久任务历史。导入报告不运行 Mole，报告数值不等于可回收空间。

**实际 Mole 分析的边界：** 目前只支持匹配精确 SHA-256 的 V1.57.0 官方发布分析器，常见官方脚本安装位置为 `~/.config/mole/bin/analyze-go`；Homebrew 与自编译版本暂不匹配该校验。每次分析前显示范围及私有临时副本/缓存写入并要求确认，可取消，失败或未知覆盖不冒充成功。工具以普通用户权限运行，没有 OS 沙箱；没有自动安装、更新、提权或目标清理。详见 [执行设计与验证](Documentation/Mole-analysis-execution-design.md)。本节描述当前源码，具体构建/测试以对应提交 CI 为准。

**预览验证记录：** `0.1.0-preview.5` 的精确源码 [`c54eb38`](https://github.com/cosZone/MoeKit/commit/c54eb38eaa56aa209c3761cc0d14e4b34caa99ed) 已在 [发布运行](https://github.com/cosZone/MoeKit/actions/runs/37192663888) 通过 246 项 Release Swift 测试、7 项合成视图渲染测试与 74 项发布辅助测试，包括实际 macOS DMG 创建、只读挂载、签名一致性与卸载检查。同源码 [Native CI](https://github.com/cosZone/MoeKit/actions/runs/37192263616) 还通过完整优化 Release、定向 AddressSanitizer 和中文渲染检查。DMG、ZIP 及校验信息已公开下载并核对；完整窗口、键盘、VoiceOver、双架构实机与真实权限仍需手动验收。

## 构建

需要 macOS 15+、Xcode 16.4 和 [Mise](https://mise.jdx.dev/getting-started.html)。以下是待在 macOS 执行的命令：

```sh
mise install
mise exec -- tuist generate --no-open
xcodebuild -workspace MoeKit.xcworkspace -scheme MoeKit \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath DerivedData CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
open DerivedData/Build/Products/Debug/MoeKit.app
```

在 Settings → Preview 中开启 Demo；也可通过 `open -n …/MoeKit.app --args --demo` 启动。`Package.swift` 仅管理 Tuist 的 SPM 依赖，目前为空；请通过生成的 Xcode workspace 构建，不使用 `swift run`。

## 下载与开发

- [Actions](https://github.com/cosZone/MoeKit/actions)：Native CI 构建与测试；手动运行 Preview app artifact 可下载包含 `.app` 的 ZIP、源码 SHA、SHA-256 校验和与构建信息
- Actions 的 Preview app artifact 仅 **ad-hoc 签名，没有 Developer ID 签名、没有公证**；该工作流不会创建 tag 或 GitHub Release
- [0.1.0-preview.5](https://github.com/cosZone/MoeKit/releases/tag/v0.1.0-preview.5) 已发布：[DMG（推荐）](https://github.com/cosZone/MoeKit/releases/download/v0.1.0-preview.5/MoeKit-v0.1.0-preview.5-macOS.dmg) · [ZIP](https://github.com/cosZone/MoeKit/releases/download/v0.1.0-preview.5/MoeKit-v0.1.0-preview.5-macOS.zip)。两种包内是同一份 universal Release App，新增可跳过、可重开的上手引导和空状态说明，保留此前的只读工作区与可靠性改进，并附校验和与构建信息
- 使用 **Apple Development 签名，未公证**，不等于 Developer ID 正式分发，Gatekeeper 仍可能阻止打开；DMG 格式不会改变这一限制
- 按版本的实际交付说明见 [preview.5 更新记录](website/content/changelog/0.1.0-preview.5.md)；preview.1 至 preview.4 保持原样。文档网站独立部署，不随 App 安装。维护者流程见 [开发签名预览发布](Documentation/Signed-preview-release.md)
- [构建与交付说明](Documentation/Build-and-preview.md)
- [架构与数据边界](Documentation/Architecture.md)
- [工具准备与安装边界](Documentation/Tool-preparation.md)
- [进程与端口的范围、隐私与验证边界](Documentation/Processes-and-ports.md)
- [上手引导与验证边界](Documentation/Getting-started.md)
- [原生验收清单](Documentation/Verification.md)

## 文档网站

Fumadocs 中文文档位于 [`website/`](website/README.md)，与原生应用同仓库、独立构建。包含功能边界、安装说明、每版本普通 Markdown 更新日志，以及可自行部署到 Dokploy 的 Docker 配置；尚未配置公开站点域名。

## 许可

项目许可证尚未确定；公开源码不代表授予额外许可。Mole 是独立上游项目，本仓库不包含其可执行文件或复制其 GPL 实现。第三方集成、分发及品牌使用需分别核对对应许可证与条件。
