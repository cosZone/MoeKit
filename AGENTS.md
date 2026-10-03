# MoeTidy 开发约定

## 当前阶段

当前仓库仅包含产品规划、开发与设计约定、品牌概念素材。没有可运行的应用、CLI 适配器或已验证的清理功能。任何文档、提交、演示或发布说明都必须区分 current、planned 和 verified；不得用占位项目或虚构测试结果表示功能完成。

## 产品与实现边界

- Swift 原生 macOS，优先 SwiftUI 与系统控件；需要窗口生命周期或系统集成时使用 AppKit。
- 优先复用用户已安装的 Git、Mole CLI、Worktrunk。先探测能力与版本，再做范围明确的适配；不自动安装工具。
- 独立编写应用与适配层，不复制第三方 GPL/AGPL 源码。项目许可证尚未决定。
- 规划期间不执行清理、删除工作区、删除分支、重置偏好或修改用户配置。
- 后续实现必须把只读扫描、操作规划、用户授权、执行与结果核验分开。
- Git 的 clean、merged、pushed、abandoned 是独立状态。ignored 的 .env、本地数据库等依然可能包含唯一数据；删除 checkout 与删除分支是独立动作。
- 不因命令包含 dry-run 或 JSON 就认为它只读。每条外部命令都需明确语义与副作用。

## 参考经验

参考 [MoePeek](https://github.com/cosZone/MoePeek) 的 Tuist/SPM、Swift 严格并发、SwiftUI/AppKit 分层、coordinator 状态机、协议适配、String Catalog 与 Swift Testing 经验。参考不等于继承所有依赖、权限、菜单栏形态或发布配置。

UI 状态使用 MainActor 隔离，后台扫描与进程执行不得阻塞主线程。Observable 状态优先 stored property；外部状态同步必须有明确观察机制。异步任务支持取消，回调、计时器、事件监听与窗口资源应及时释放。

具体结构与验证计划见 [开发约定](docs/development.md)，交互与品牌见 [设计约定](docs/design.md)。后续新增构建、测试、发布步骤时，只记录实际可运行并验证的命令。
