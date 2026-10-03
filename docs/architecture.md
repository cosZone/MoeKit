> 历史专项规划：以下内容主要描述项目产物与清理安全等未来能力，不是当前已实现清单。MoeKit 的最新定位为个人 CLI 原生工具箱；当前实现和验证状态见 [README](../README.md)。

# 技术结构与权限验证

状态：planned。本文是产品与实施蓝图，尚无可运行应用或已验证的执行能力。

## 技术结构规划

- **App / DesignSystem：** SwiftUI 页面、列表、检查器、审核窗口、无障碍语义和少量设计 token
- **Domain：** Project、RepositoryIdentity、Workspace、Artifact、Evidence、Plan、Operation；纯模型与规则
- **Discovery：** 有预算的目录枚举、身份识别、缓存失效、权限状态
- **GitService：** 类型化请求、版本能力、字节解析、检查快照与受约束的 Git 操作
- **ToolAdapters：** Git、Mole；后续 Worktrunk/gfold，隔离各版本和输出协议
- **Planning / Execution：** 不可变计划、风险规则、重叠去除、复查、串行化、取消、核验
- **Recovery / Persistence：** 持久操作日志、恢复材料索引和完整性检查；原型可用小型 Codable 存储，增长后评估 SQLite
- **Fixtures / Tests：** 一次性仓库、文件树、适配器录制样本和进程故障模拟

Swift concurrency 负责可取消后台任务；UI 只消费可展示的快照。执行器、文件系统与进程访问通过可替换边界注入，以便不触碰用户真实目录就能测试危险情况。

### 权限与分发需要先验证

优先验证签名、公证的直接分发路线，但当前没有分发产物。Sandbox、安全作用域书签、外部 executable 和跨目录 Git 布局之间的限制应做早期原型，不能在文档里假定已经解决。

应用不默认要求 root helper、管理员密码或 Full Disk Access。选择一个根目录不等于获得另一个 worktree/common directory 的权限；需要访问时解释具体用途。[Apple App Sandbox 文件访问](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) · [Apple 公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

返回 [README](../README.md) · [文档目录](README.md)
