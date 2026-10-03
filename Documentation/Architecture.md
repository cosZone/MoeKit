# 架构与数据边界

## 原生工作台

`MoeKitApp` 创建共享的 `WorkspaceStore`。SwiftUI `NavigationSplitView` 承载 Projects / Tools / Tasks，项目使用 `Table` 和 inspector，任务详情停靠于底部。AppKit 仅用于原生文件选择器与 Finder 定位。导航与操作图标使用 SF Symbols；应用图标和品牌图像来自 `Resources/Brand`。

`ToolModule` / `ToolModuleDescriptor` / `ToolModuleRegistry` 描述内置集成、稳定 ID、可搜索的模块数据和能力可用性；当前 UI 直接导航到 Mole，尚无独立目录搜索界面。新增内置模块不应改变顶层导航。目前仅注册 Mole，所有命令执行能力均明确不可用。它不是动态插件宿主，不加载任意二进制或脚本。

## Projects：读取与保存

- 用户主动选择根目录；发现器是 Foundation actor，不调用 Git、shell、项目脚本或 hooks
- 默认最多 4 层、2,000 个目录、100,000 个枚举项；Git 元数据每次最多 16 KiB
- 跳过符号链接、隐藏目录、常见依赖/构建目录；发现 Git 根后不继续深入该仓库
- `.git` 目录或文件仅用于识别布局及读取 HEAD；工作树状态未检查，分支显示也不是实时 Git 状态
- Git file 可代表 worktree 或 submodule 布局；不能据此推断上游关系。外部元数据路径受范围检查，发现中的权限、范围或限制问题会记录为不完整结果
- 目录读取与符号链接检查是变动文件系统中的尽力检查，不是消除 TOCTOU 的安全边界
- 仅写入自身 `~/Library/Application Support/MoeKit/projects.json`，保存项目路径、名称、置顶状态与最近 Finder 定位时间；不修改被选择的项目内容

此预览没有 App Sandbox entitlement。文件选择与范围限制属于应用行为约束，不构成系统强制的沙箱隔离。拒绝读取、路径失效和未读到的元数据均不可伪装成正常或零值。

## Mole：只读报告

`MoleAnalyzeReport` 解码 Mole `analyze --json` 报告，限制导入文件为 16 MiB。导入只读取用户选择的 JSON，不运行 Mole，也不按报告路径继续读取或修改文件。

覆盖状态保留 known / partial / unavailable / unknown 语义；不可用不能显示为零字节。概览位置可能重叠，不能相加作为全盘分区。只有非概览、已知覆盖、唯一行及总和一致时才显示可加比例。导入时间不代表测量时间；上游大小不等于物理占用、可删除量或可回收空间。

## Demo 与任务

真实项目和任务初始为空，项目目录从本地持久化加载。Demo 必须显式启用，使用 `DemoData` 与页面中的示例报告；有持续可见标识，不向真实项目目录写入示例项目。退出 Demo 恢复真实数据。任务记录和已导入报告仅保留于当前进程。

Swift Testing 测试覆盖扫描边界、取消、异常元数据、模块注册与报告解码。源码中存在测试不代表测试已运行；结果应按精确提交查验 CI。
