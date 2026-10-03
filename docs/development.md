# 开发与验证约定

状态：planned。当前没有 Swift 工程或可执行构建、测试、发布流水线。

## 参考项目

[MoePeek](https://github.com/cosZone/MoePeek) 使用 Tuist 生成工程、SPM 管理依赖、Swift 6 严格并发、SwiftUI/AppKit、Swift Testing，以及英文/简体中文 String Catalog。其项目指导位于 [CLAUDE.md](https://github.com/cosZone/MoePeek/blob/main/CLAUDE.md)，工程配置见 [Project.swift](https://github.com/cosZone/MoePeek/blob/main/Project.swift)。

可复用的是分层、状态管理、构建配置和验证方法，不是整套翻译业务实现。MoeTidy 的最低 macOS 版本、依赖清单和签名方案仍需在实施阶段确认。

## 计划工程结构

| 目录 | 计划职责 |
| --- | --- |
| Sources/App | 入口、窗口和生命周期装配 |
| Sources/Core | 扫描协调、状态机、风险判定与操作计划 |
| Sources/Services | 工具能力探测、Git/Mole/Worktrunk 适配与进程运行 |
| Sources/UI | 概览、清理候选、工作区详情、操作审阅和设置 |
| Sources/Utilities | 路径、偏好、日志脱敏和通用辅助 |
| Tests | 解析、风险判定、取消与执行边界测试 |
| Resources | 本地化及品牌素材 |

以上是结构蓝图，目录和类型不代表实现已经存在。

## 状态与并发

- UI/coordinator 的界面状态由 MainActor 管理，Observable 暴露清晰 stored state；耗时扫描与子进程放在适当后台隔离域。
- 扫描、规划、等待授权、执行、成功、部分失败、取消必须有独立状态，旧请求结果不能覆盖新请求。
- 子进程取消应终止对应任务并收集退出状态；输出量、超时和重复执行需要约束。
- 存储闭包与系统监听避免循环引用；窗口关闭、计时器停止和流终止均应释放资源。
- 命令采用明确 executable 与 argv，不拼接 shell 字符串执行用户路径。解析器与能力探测独立于 UI。

## 验证计划

采用 Swift Testing 验证有意义的行为：Git porcelain/NUL 分隔输出、特殊路径、版本差异、ignored 文件保护、分支与 checkout 分离、扫描取消、计划过期重检、部分执行失败、工具缺失与输出变化。集成测试只用临时夹具仓库和临时目录，禁止以真实用户工作区执行删除测试。

首次进入实现阶段应固定并记录 Tuist/Swift/Xcode 版本，提供可复现生成、构建与测试命令。版本命令成功不等于适配器兼容测试通过；安装工具不等于支持该版本。

## 发布计划

借鉴 MoePeek 的 SemVer、单一版本来源、忽略个人 Signing.xcconfig、保留示例配置、签名验证和 draft 测试发布经验。若未来采用 Sparkle，需单独设计密钥管理和测试期间更新器隔离。

MoePeek 的现有发布 workflow 未包含测试门禁或 Apple 公证；MoeTidy 不直接沿用这一缺口。未来发布需完成 CI 构建与测试、稳定签名、合适的公证与分发验证、发布材料检查，再建立正式发布流程。当前不创建标签、发布下载链接或可用性徽章。

许可证及分发方式未决定；对源码、工具调用、捆绑和分发分别做依赖与许可记录，不在本文推断商业分发结论。

返回 [README](../README.md) · [设计约定](design.md)

## MoePeek 经验映射

已检查 [cosZone/MoePeek](https://github.com/cosZone/MoePeek)，基线为 v0.19.2 / `ee75bd7`。以下是参考项目的观察结果，不是 MoeTidy 已建立的工程或已通过的构建声明。

| MoePeek 已验证约定 | MoeTidy 计划借鉴 |
| --- | --- |
| Swift 6 strict concurrency、macOS 15+、SwiftUI/AppKit | 原生技术栈及明确的并发隔离；先验证 Git/Process 与取消流程 |
| Tuist 4.148.3 + SPM | 评估采用同类工程生成与依赖组织，让维护方式与已有项目一致 |
| `@MainActor` + `@Observable` | UI 状态隔离，后台 IO 返回可展示快照 |
| protocol / registry / coordinator 分工 | 用协议隔离适配器和执行器，以 coordinator 组织审核流程 |
| App / Core / Services / UI / Utilities 目录 | 参考模块职责，再按 Git、产物和恢复领域调整 |
| en/zh String Catalog | 中英双语、状态与危险操作文案集中管理 |
| Swift Testing | 建立纯规则、解析器和一次性仓库的测试基础 |
| CLAUDE.md 强调弱引用、窗口/timer 清理、异步取消 | 将窗口生命周期、资源释放和取消作为工程验收项 |
| 签名配置以被忽略的本地文件和 `.example` 区分 | 不提交凭据或本机签名信息；提供不含秘密的配置样例 |

MoePeek 的参考构建步骤是 `tuist install`、`tuist generate --no-open`，再使用 xcodebuild；这些不能直接当成 MoeTidy 当前的运行说明。工程生成并实际构建成功后，再记录 MoeTidy 自己的准确 scheme、配置和命令。

现有参考 release workflow 没有覆盖测试与公证步骤。MoeTidy 可学习其组织方式，但应在自身发行门槛中补齐相应验证，不沿用这项缺口。参考项目的已观察结构不等于允许复制其源码；拟复用任何文件之前仍需核实许可与适用性。
