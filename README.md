# MoeKit

面向 macOS 的个人 CLI 工具箱：把项目、工具和任务放进一个原生工作台。Mole 是首个内置模块，整体架构为更多个人常用工具保留扩展位置。

Swift 6 · SwiftUI / AppKit · macOS 15+ · Tuist 4.148.3 · SPM

## 当前预览

已经写入源码：
- **Projects**：原生表格、搜索与排序、项目详情 inspector、置顶项目、Finder 定位；多根目录只读发现 Git 项目，复查筛选后导入/刷新；验证 worktree 关系后分组，展示带时间的分支/锁元数据；源码新增单独确认的干净 linked worktree 退役与已合并 loose 本地分支移除
- **Tools**：Mole 的 Space / Clean / Apps / Maintenance / Status 工作区；Space 可导入 Mole analyze JSON，也可选择已安装的官方 V1.57.0 直接分析器与单个文件夹，复查确认后实际分析；Processes & Ports 可由用户主动读取当前用户进程和 TCP 监听端口，按工作目录展示项目关联
- **下载磁盘映像**：从本机 Downloads 当前真实 Mole 分析中选择一个常规 `.dmg`，独立复查路径、大小和影响，确认已结束使用后移到 macOS 原生废纸篓；私有凭据支持另行确认的原路径恢复，不覆盖已有目标、不清空废纸篓
- **Processes & Ports**：原生密集表格、身份与关联证据、部分读取提示、项目相关进程入口，以及逐次确认的精确选择停止；先发送 SIGTERM，仍在运行的同一身份才可另行确认 SIGKILL；浏览器/应用/共享服务/系统/自身及祖先进程受保护，不读取参数或环境变量，不自动扫描或停止
- **工具准备**：从 Settings 或 Mole 打开，主动检查固定常见位置或自选文件的元数据，区分未检查、该路径未找到、找到但未验证、不支持与无法读取；提供官方安装说明和复制命令，不安装、不探测版本、不运行 CLI
- **Tasks**：本次会话的发现任务、取消、状态与底部结果详情；可展开 Diagnostics
- 独立 Demo 开关与明确示例标识；正常启动无虚构项目、运行结果或磁盘测量
- 可跳过、可重开的上手引导：项目整理、进程查看或示例体验；先说明范围，再由用户主动选择文件夹或开始扫描
- **当前源码，尚未包含在 preview.8 安装包**：菜单栏原生入口，Dock / 菜单栏图标独立设置与重开恢复；主动检查 GitHub 新版本并手动下载，尚未启用 Sparkle 自动安装。详见 [更新与应用入口](Documentation/Updates-and-app-icons.md)
- 原生 NavigationSplitView、Table、工具栏与 SF Symbols；自定义应用图标

尚未实现：任意 CLI 执行、AI 专用无头浏览器归属与清理、广域 Mole 清理、卸载、维护、实时系统指标、提权、第三方插件加载及持久任务历史。导入报告不运行 Mole，报告数值不等于可回收空间。

**实际 Mole 分析的边界：** 目前只支持匹配精确 SHA-256 的 V1.57.0 官方发布分析器，常见官方脚本安装位置为 `~/.config/mole/bin/analyze-go`；Homebrew 与自编译版本暂不匹配该校验。工具准备页提供精确受支持文件的手动下载链接与复制命令，校验大小和 SHA-256 后才添加执行权限；详见 [工具准备](Documentation/Tool-preparation.md)。每次分析前显示范围及私有临时副本/缓存写入并要求确认，可取消，失败或未知覆盖不冒充成功。工具以普通用户权限运行，没有 OS 沙箱；没有自动安装、更新、提权；Mole 分析本身不执行目标清理。详见 [执行设计与验证](Documentation/Mole-analysis-execution-design.md)。本节描述当前源码，具体构建/测试以对应提交 CI 为准。

**下载磁盘映像操作的边界：** 仅支持本地内置 APFS 上、Downloads 直属的单个常规 `.dmg`；导入 JSON、Demo、`.pkg`、链接、云占位、项目与 worktree 不能授权。必须取得完整且为空的磁盘映像清单；只可自行推出自己打开的映像，不要触碰系统管理的映像，系统映像仍存在时此操作不可用。当前用户文件描述符／fileport 检查不等于全局未使用证明，无法覆盖所有内存映射、系统服务和其他用户。每次操作及恢复都重新复查并确认，移入废纸篓不会释放占用空间；不确定结果保留数据并停止。详见 [设计与恢复边界](Documentation/Installer-trash-design.md)。

**未发布的 Git 整理：** Projects → Git cleanup… 可单独复查并确认一个干净 linked worktree 的退役，或一个未检出且完全包含于指定本地 base 的 loose 分支移除。所有数据移入主仓库的私有恢复目录，保留分支或 ref 备份；会话内另行确认恢复，不覆盖、不 force、不永久删除，也不释放磁盘空间。拒绝脏文件、untracked／ignored、独有提交、锁、链接、跨范围及不支持布局；Git 只查看配置隔离的对象副本。详见 [设计与限制](Documentation/Git-cleanup-design.md)。此功能不包含在已发布的 preview.8。

精确分析器下载指引和原生单个 `.dmg` 操作从 preview.7 起交付；preview.8 保留这些能力，并新增独立的精确进程停止与原生缓存工作流。

**预览验证记录：** `0.1.0-preview.8` 的精确源码 [`b0bdd59`](https://github.com/cosZone/MoeKit/commit/b0bdd59ff672efe16a23a20b422e0e433179be11) 已完成 [发布运行](https://github.com/cosZone/MoeKit/actions/runs/37225799139)，提供通过公开下载字节、校验和、来源与完整 App 内容摘要核对的 DMG／ZIP。主 App 与原创监督辅助程序均完成双架构开发签名验证。发布 Swift Testing 报告 458 项，其中 7 项 opt-in 原生检查跳过，另有 14 项 XCTest 与 89 项发布辅助测试通过；实际原生缓存、进程与安装器 fixture 以同源码 [Native CI](https://github.com/cosZone/MoeKit/actions/runs/37225038573) 为准。该 CI 的安装器使用证据 job 正确拒绝当前非空映像环境，未建立当前 `noUseObserved`。完整验证边界见 [preview.8 记录](website/content/changelog/0.1.0-preview.8.md)；完整窗口、键盘、VoiceOver、双架构实机与真实目录权限仍需手动验收。

## preview.8：真实缓存清理

Tools → Mole → Cleanup 新增原生批量缓存清理：主动检查用户缓存目录 → 选择多个精确缓存 → 复查完整清单并确认 → 移入废纸篓；每项记录可独立确认原路径恢复，或另行确认不可恢复的永久移除。移动到废纸篓不释放空间，永久移除也不保证等量物理空间立即回收。此工作流已随 preview.8 交付，preview.7 不包含；验证记录绑定上方精确源码，后续源码改动不自动进入已发布安装包。支持范围、限制和使用方式见 [原生缓存清理](Documentation/Native-cache-cleanup.md)。

## 构建

需要 macOS 15+、Xcode 16.4 和 [Mise](https://mise.jdx.dev/getting-started.html)。以下是待在 macOS 执行的命令：

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

在 Settings → Preview 中开启 Demo；也可通过 `open -n …/MoeKit.app --args --demo` 启动。`Package.swift` 仅管理 Tuist 的 SPM 依赖，目前为空；请通过生成的 Xcode workspace 构建，不使用 `swift run`。

## 下载与开发

- [Actions](https://github.com/cosZone/MoeKit/actions)：Native CI 构建与测试；手动运行 Preview app artifact 可下载包含 `.app` 的 ZIP、源码 SHA、SHA-256 校验和与构建信息
- Actions 的 Preview app artifact 仅 **ad-hoc 签名，没有 Developer ID 签名、没有公证**；该工作流不会创建 tag 或 GitHub Release
- [0.1.0-preview.8](https://github.com/cosZone/MoeKit/releases/tag/v0.1.0-preview.8) 已发布：[DMG（推荐）](https://github.com/cosZone/MoeKit/releases/download/v0.1.0-preview.8/MoeKit-v0.1.0-preview.8-macOS.dmg) · [ZIP](https://github.com/cosZone/MoeKit/releases/download/v0.1.0-preview.8/MoeKit-v0.1.0-preview.8-macOS.zip)。两种包内是同一份 universal Release App，新增逐次确认的精确进程停止、原生多缓存废纸篓、原路径恢复与另行确认的记录内缓存永久删除，并保留此前的 Mole 分析与单个 Downloads `.dmg` 操作；附校验和及构建信息
- 使用 **Apple Development 签名，未公证**，不等于 Developer ID 正式分发，Gatekeeper 仍可能阻止打开；DMG 格式不会改变这一限制
- 按版本的实际交付说明见 [preview.8 更新记录](website/content/changelog/0.1.0-preview.8.md)；preview.1 至 preview.7 保持原样。文档网站独立部署，不随 App 安装。维护者流程见 [开发签名预览发布](Documentation/Signed-preview-release.md)
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
