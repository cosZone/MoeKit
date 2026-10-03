# MoeKit

面向 macOS 的个人 CLI 工具箱：把项目、工具和任务放进一个原生工作台。Mole 是首个内置模块，整体架构为更多个人常用工具保留扩展位置。

Swift 6 · SwiftUI / AppKit · macOS 15+ · Tuist 4.148.3 · SPM

## 当前预览

已经写入源码：
- **Projects**：原生表格、搜索与排序、项目详情 inspector、置顶项目、Finder 定位；多根目录只读发现 Git 项目，复查筛选后导入/刷新；验证 worktree 关系后分组，展示带时间的分支/锁元数据和不可执行的清理安全复查
- **Tools**：Mole 的 Space / Clean / Apps / Maintenance / Status 工作区；Space 可导入 Mole analyze JSON；Processes & Ports 可由用户主动读取当前用户进程和 TCP 监听端口，按工作目录展示项目关联
- **Processes & Ports**：原生密集表格、身份与关联证据、部分读取提示、项目相关进程入口，以及不可执行的精确选择停止计划预览；不读取命令参数/环境变量，不自动扫描或发送进程信号
- **Tasks**：本次会话的发现任务、取消、状态与底部结果详情；可展开 Diagnostics
- 独立 Demo 开关与明确示例标识；正常启动无虚构项目、运行结果或磁盘测量
- 原生 NavigationSplitView、Table、工具栏与 SF Symbols；自定义应用图标

尚未实现：CLI 进程执行、停止/强制停止、清理、卸载、维护、实时系统指标、提权、第三方插件加载及持久任务历史。导入报告不运行 Mole，报告数值不等于可回收空间。

**预览验证记录：** `0.1.0-preview.3` 的精确源码 [`cc891fd`](https://github.com/cosZone/MoeKit/commit/cc891fd370ac5e0d261c66e8320c3de5c50438d3) 已在 [发布运行](https://github.com/cosZone/MoeKit/actions/runs/37148654870) 通过 205 项 Release Swift 测试、4 项合成视图渲染测试与 74 项发布辅助测试，包括实际 macOS DMG 创建、只读挂载、签名一致性与卸载检查。DMG、ZIP 及校验信息已公开下载并核对。合成视图检查不代替完整原生窗口、键盘、VoiceOver、双架构实机与真实权限验收；后续源码以对应 CI 为准。

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
- [0.1.0-preview.3](https://github.com/cosZone/MoeKit/releases/tag/v0.1.0-preview.3) 已发布：[DMG（推荐）](https://github.com/cosZone/MoeKit/releases/download/v0.1.0-preview.3/MoeKit-v0.1.0-preview.3-macOS.dmg) · [ZIP](https://github.com/cosZone/MoeKit/releases/download/v0.1.0-preview.3/MoeKit-v0.1.0-preview.3-macOS.zip)。两种包内是同一份 universal Release App，包含多根目录项目复查、进程筛选、工作区可靠性改进与 About／Feedback／Give a Star 入口，并附校验和与构建信息
- 使用 **Apple Development 签名，未公证**，不等于 Developer ID 正式分发，Gatekeeper 仍可能阻止打开；DMG 格式不会改变这一限制
- 按版本的实际交付说明见 [preview.3 更新记录](website/content/changelog/0.1.0-preview.3.md)；preview.1 与 preview.2 保持原样。文档网站独立部署，不随 App 安装。维护者流程见 [开发签名预览发布](Documentation/Signed-preview-release.md)
- [构建与交付说明](Documentation/Build-and-preview.md)
- [架构与数据边界](Documentation/Architecture.md)
- [进程与端口的范围、隐私与验证边界](Documentation/Processes-and-ports.md)
- [原生验收清单](Documentation/Verification.md)

## 文档网站

Fumadocs 中文文档位于 [`website/`](website/README.md)，与原生应用同仓库、独立构建。包含功能边界、安装说明、每版本普通 Markdown 更新日志，以及可自行部署到 Dokploy 的 Docker 配置；尚未配置公开站点域名。

## 许可

项目许可证尚未确定；公开源码不代表授予额外许可。Mole 是独立上游项目，本仓库不包含其可执行文件或复制其 GPL 实现。第三方集成、分发及品牌使用需分别核对对应许可证与条件。
