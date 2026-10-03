# 原生验收清单

以下为待完成检查，不是通过记录。验收时记录源码 SHA、app 校验和、macOS/Xcode 版本、硬件架构及实际结果；CI 通过不能代替视觉和辅助功能测试。

## 自动检查

- [ ] `python3 Scripts/verify-source.py`：记录结果，确认不是 Swift 编译检查
- [ ] 固定版本 Tuist 可生成 workspace；MoeKit scheme 包含 MoeKitTests
- [ ] macOS 构建和 Swift Testing 全量测试通过；保留 `.xcresult`
- [ ] Native CI 检查构建后的 SwiftUI bundle 元数据，并在无签名 Secret 的 runner 中以 `--demo` 启动 10 秒；该检查仅证明进程未提前退出，不代表窗口渲染、交互或辅助功能已验收
- [ ] 手动 preview artifact 的源码 SHA 与目标提交一致；校验和与签名验证通过

## 原生视觉与操作

- [ ] 浅色/深色下 Sidebar、Table、toolbar、inspector、底部详情无截断、重叠或异常底色
- [ ] 960×620 最小窗口、默认窗口、全屏以及 Sidebar / inspector 开关均可用
- [ ] Projects 搜索、排序、选择、置顶、展开/折叠可连续操作；过滤后不会对不可见旧选择误操作
- [ ] Tasks 底部结果摘要、条目和 Diagnostics 展开区、空日志和长路径可读；调整布局不丢失选择
- [ ] Command-O、菜单操作、键盘焦点、Tab/Shift-Tab、方向键与 Escape 行为符合 macOS 预期
- [ ] 中英文切换后标题、占位、动态状态、错误信息和菜单可读，长翻译不会破坏布局
- [ ] 图标在 Dock、Finder、Settings 下清晰；导航和操作符号来自 SF Symbols

## 空状态与 Demo

- [ ] 独立测试账户或干净 catalog 首次启动显示空 Projects / Tasks，没有虚构成功与磁盘测量
- [ ] 显式开启 Demo 后持续可见示例标识，示例项目与任务足够检验密集列表
- [ ] Demo 下不能导入项目/报告、定位虚构路径或执行清理；退出后恢复真实目录
- [ ] 多次进入/退出 Demo、切换页面与关闭窗口，不泄漏旧选择或示例任务到真实数据
- [ ] 正常退出后重开，真实项目与置顶状态恢复；任务与导入报告不宣称已持久化

## 读取、取消与失败

- [ ] 取消文件夹选择器、报告选择器、发现结果窗口：不导入、不改变原 catalog
- [ ] 扫描中取消，再次开始扫描或切换页面：旧结果不能覆盖新操作；任务显示正确终态
- [ ] 重复点击发现不会重复启动；扫描中 Demo 开关行为受控
- [ ] 空目录、普通目录、标准 Git、worktree/gitfile、损坏 HEAD、超大元数据、无读取权限目录
- [ ] 超过深度/目录/枚举项限制时标注不完整；符号链接循环、依赖目录和 build 输出被跳过
- [ ] 外部 gitdir/commondir、符号链接元数据不被当作已完整读取；取消后无项目文件变动
- [ ] catalog 损坏或不可写时有明确提示，不悄悄覆盖现有内容
- [ ] JSON 超过 16 MiB、格式错误、负数/溢出、未知 coverage 都能安全失败或显示真实覆盖状态
- [ ] Mole 概览重叠目录不显示可加比例；partial/unavailable 不伪装为完整零值；导入时间不充当测量时间
- [ ] Clean / Apps / Maintenance / Status 明确显示尚未接入，不生成伪成功结果

## 辅助功能与交付

- [ ] VoiceOver 能识别每个按钮、搜索框、行、选中状态、展开按钮和详情分区
- [ ] 无障碍名称不依赖图标；错误、运行与 Demo 状态不只靠颜色表达
- [ ] 增强对比度、减少透明度及较大文字设置下仍清晰；仅键盘能完成主要流程
- [ ] Apple Silicon 与 Intel 分别实机启动验证；未测试的平台必须保持“未验证”
- [ ] 下载产物的 Gatekeeper 行为如实记录，不通过脚本改变安全设置
- [ ] 按实际证书类型（本预览为 Apple Development）签名后，分别验证签名、校验和与公证状态；发布前另行审核

## Processes & Ports（待验证）

- [ ] 首次进入、打开项目关联、切换 Tools 不自动扫描；当前用户范围和读取隐私提示清楚
- [ ] 扫描、取消、刷新、切换 Demo、切换项目筛选、改变搜索或选择后，旧结果与旧计划不会误复用
- [ ] 快照时间、部分结果、无权限字段、未知端口与确认未观察到监听端口均能区分
- [ ] IPv4/IPv6 TCP 本地监听端口正确；UDP/已连接 socket 不冒充 TCP listener；权限/数量/时限截断显示未知
- [ ] 真实 Mac 上验证 libproc 的 SDK 可用性、目录权限与退出/exec 期间的读取行为；不得把 synthetic fixture 测试称作真实进程覆盖
- [ ] 个人浏览器、IDE、数据库、VM、共享 shell 的风险提示正确；关联不冒充 MoeKit 管理
- [ ] 停止计划仅列出精确选择项；无自动扩展父子进程/组，无可执行 Stop/Force Stop 按钮
- [ ] 中英文、960×620、深浅色、VoiceOver 和纯键盘下表格/详情/计划可读


## 多根目录与 worktree 发现

以下原生交互仍需在 macOS 验收，不等于已人工通过：

- 同时选择主仓库及它的 linked worktree：只读发现后复查、筛选、排序、全选可见与清空选择；导入后 worktree 应位于主仓库下
- 仅选 worktree 且 Git 目录在范围外：分支/关系保持未知并产生诊断；不要伪装成 clean 或可清理
- 分别验证绝对/相对 gitfile、有效 backlink、缺失/不匹配 backlink、commondir 符号链接、Git worktree lock、submodule 风格 gitfile
- 重复导入刷新分支，保留选中项目的稳定 ID、置顶和最近定位时间；不要复制项目行
- 多根目录共享扫描预算；重叠范围不重复结果，目录失败不丢弃其他可读根目录；部分结果在 Tasks 中列出原因
- 扫描期间取消、快速切换 Demo 后退出、再次扫描；不得把取消或 Demo 前的结果带入新的导入复查
- 展开/折叠、置顶/最近筛选、搜索子 worktree、改变排序；不可见项目应清除选择，操作按钮不能继续指向隐藏行
- 打开清理安全复查：所有项目都处于保护状态，明确未检查的本地变更、未跟踪/未推送内容与活动状态；没有删除或回收量承诺
- 使用 VoiceOver 检查扫描进度、锁标识、展开按钮、复查选择计数与取消/完成按钮；检查小窗口、长路径与深浅色模式

## 工作区可靠性与渲染证据

- Native CI 的 `UISnapshotTests` 在临时空 catalog 中显式开启 Demo，以 AppKit 绘制测试拥有的 `WorkspaceView` 子树，覆盖 Projects inspector、Tasks 结果、Mole Space 与 Processes Demo 禁用状态的两种尺寸和深浅色，共 16 个 PNG
- PNG 与范围说明随 `.xcresult` 保存，并导出到 `native-view-renders-<SHA>` artifact；测试仅检查可绘制且非空白，必须人工查看实际图片，不能把通过记录当成视觉验收
- 不截取桌面或其他窗口，不请求屏幕录制或 Accessibility 权限，不读取真实 catalog，不扫描真实目录/进程；不改变签名和发布流程
- 范围不含原生标题栏/工具栏、键盘操作、VoiceOver、真实 Mac、中文布局或像素回归基线；Demo 相对时间使图片不是稳定基线
- [ ] 在活动工作区中用 Edit → Search workspace / Command-F 聚焦对应搜索框；Escape 先清空搜索，再移出焦点；切换工作区后不得继续编辑旧搜索
- [ ] Command-Option-I 切换项目 inspector；打开 About、Settings 或发现复查时，不应把搜索命令发送到不可见工作区
- [ ] 项目折叠/筛选/移除、任务筛选/完成后，旧选中项立即清除；清空筛选不复活旧选择
- [ ] 960×620 且 inspector 打开时，Finder、Project actions、路径与空状态可读；Project actions 中置顶、关联进程和安全复查指向当前可见选择
- [ ] 发现复查筛选隐藏了已选项目时，隐藏选择数量和最终总导入数量明确显示
- [ ] Demo 与真实模式之间清空搜索/筛选/选择；Demo 任务计数来自示例记录，空搜索结果不能显示真实导入提示
