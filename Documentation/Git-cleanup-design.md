# 逐次确认的 Git 整理

本改动是未发布源码。它不复用暂停的 XPC／bookmark 原型，也不声称存在 OS 沙箱。准确构建、测试和签名结果以本提交 CI 为准。

## 可执行的两个独立操作

从 Projects 的「Git cleanup…」进入，显式选择同时包含主仓库和目标 worktree 的父目录，填写要保留的本地 base 分支，然后检查精确目标。

1. **退役一个 linked worktree**：普通 tracked 文件必须逐字节匹配 index；index 重建的 tree 必须匹配分支提交；该提交必须是保留 base 的祖先。把 worktree 和其 `.git/worktrees/<id>` 登记分别独占移动到主仓库 `.git/moekit-recovery/<操作 UUID>/`。原分支不删除
2. **删除一个已合并的本地分支**：单独输入分支并重新检查、确认；必须是未被任何 worktree 检出的 loose ref，且完全包含于用户指定的本地 base。只把该 ref 移入同样的恢复目录，保留 reflog 和 branch 配置，不改远端分支

两项确认互不授权；都没有 force、递归删除或永久删除入口。用户必须确认已经关闭使用目标的编辑器、终端及 Git 操作，并输入精确分支名。计划最多有效 120 秒、只可用一次；真正移动前再次完整检查提交、目录、index、文件、对象来源和目录清单。移动后从目录清单移除已退役工作树；会话内另行确认恢复后加回。

**退役和移入恢复目录不释放磁盘空间。** 恢复目录内保留全部文件与分阶段 JSON 记录。会话内可另行确认恢复，不覆盖原路径、ref 或登记；重启后不自动扫描／恢复这些记录，也不自动删除恢复数据。ref 备份保存的是引用字节，Git 对象仍服从仓库自身的保留和 GC 规则；不要把它当作独立 Git bundle 或异地备份。

## 有意限定的首个子集

- 同一台机器上的本地可写同卷目录，逐级拒绝符号链接与不可信写权限／ACL；主仓库和 worktree 都在明确范围内
- 普通 SHA-1、files refs、index v2，普通 100644／100755 文件；index checksum、排序、路径、Unicode／大小写别名、stage 和 flags 均检查
- 有界 TREE cache 可跳过，但 tree OID 重新计算；拒绝其它 index 扩展、assume-valid、skip-worktree、split／sparse index、冲突、symlink、gitlink／submodule
- 配置 includes、filter、extensions、partial clone、非默认内容转换、额外属性、shallow、alternates、replace、grafts、reftable、未知状态不支持
- 目标不得是主 worktree、保护分支、被锁定目标；有 staged／modified／untracked／ignored 文件、额外空目录、独有提交或嵌套目录清单项目时拒绝
- 删除目标若同时出现在 packed-refs 中也拒绝，避免 loose ref 移走后旧 packed 值重新出现；不会为一个分支重写全部 packed-refs
- 所有登记的 HEAD 都必须可识别。当前分支、其它 worktree 检出的分支和损坏登记均受保护
- 每次目录 capture 最多 20,000 个条目、48 层、单文件 64 MiB；工作树／元数据各 64 MiB，对象库 256 MiB；单次 capture 的协作式预算 30 秒

这些限制会拒绝一部分实际可用 Git 仓库，不把未知结果显示成 clean。未支持的情况应在 Git 中人工处理。不会临时移除属性、忽略规则或配置后声称它们已被完整支持。

## 为什么 Git 不接触 live 仓库

原生读取器使用 anchored descriptors、`openat`／`O_NOFOLLOW` 和前后身份检查，逐层检查目录与文件 ACL。临时执行根也经过描述符锚定和私有 ACL 校验，每次执行前重新核对复制二进制身份与 SHA-256，清理前核对原根身份及所有权标记。它自己解析 index 并计算 tracked blob/tree SHA-1，不运行 status、diff、filter 或 hooks。文件集合完全匹配 index 才通过，所以 ignored 文件也受保护。

对象库仅允许标准 loose object 和 pack/idx/rev/keep 文件，普通逐字节复制到独占 0700 临时目录。不会带入 live config、refs、index、HEAD、attributes、alternates、hooks、远端配置或 worktree 路径。新建的是 app 自己的 bare config、占位 HEAD 和空 refs。Git 先执行固定 `--version` 验证，再只执行两个固定对象操作：`rev-parse --verify <sha>^{tree}` 与 `merge-base --is-ancestor <sha> <base-sha>`。引用参数仅接受 40 位小写十六进制。

系统／全局配置关闭，环境从固定 allowlist 新建，无继承 GIT_*／DYLD_*／开发工具变量；协议禁止、lazy fetch 禁止、stdin 关闭，无 shell。原创 `GitObjectInspector` supervisor 负责 15 秒墙钟、10 秒 CPU、零文件输出、128 B stdout／64 KiB stderr 上限、拥有的子进程组终止与回收。macOS 用 `proc_pidinfo(PROC_PIDTASKINFO)` 在 25 ms 轮询边界监视本次拥有的直接子进程 RSS，超过 512 MiB 或无法读取仍在运行的进程指标时停止并回收；退出竞态通过保留 PID 的 waitid 再检查区分。RSS watchdog 可能在采样间隔内超调，不是内核强制的硬上限，也不覆盖全部 mmap、内核内存或后代进程合计。Linux helper fixture 保留独立的 hard data limit，不能把 Linux 证据当作 macOS 的同等内存机制。Swift capture 和同步文件系统调用也不是强制可中断系统调用沙箱。

### Apple Git 的来源与临时复制

只尝试固定的已安装 Apple Command Line Tools、Xcode.app 或 CI 的 Xcode_16.4 工具链目录；不使用 `/usr/bin/git` 的按需安装 shim，不搜索 PATH、不安装或下载 Git。读取有界普通二进制后在 app 私有目录创建临时副本，验证副本的 Apple code-signing trust anchor 再运行。这样安装目录后来替换文件不会换掉本次已验证的字节。要求明确的 Apple Git 版本格式、Git 2.39.5／Apple Git-154 或更新的 2.x 版本；检查结果记录版本，并把副本 SHA-256 纳入计划指纹。未知签名、旧版、缺失工具链或不支持固定命令的版本直接拒绝，不降级。此版本下限是已配置 Xcode 16.4 测试基线，不是对所有已知／未知漏洞的无条件安全背书；用户仍应保持 Apple 工具链更新。

本项目不分发、不提交、不修改、不重签名任何 Apple Git 二进制，也不复制 Git 源码。Git 上游采用 [GPL v2](https://github.com/git/git/blob/master/COPYING)，此处为已安装工具的本机临时调用，不加入第三方运行时库或二进制发布资产。新增原创 helper 仍必须经过精确名称、双架构、代码签名与发布 allowlist 独立审查。发布检查明确拒绝打包一个 `Contents/MacOS/git`。

## 一致性、恢复和明确的不保证

移动使用同卷 `renameatx_np(RENAME_EXCL)`，不覆盖目标；操作同时持有适用的目标／base loose-ref `.lock` 和 `packed-refs.lock`，在锁内再次复核 ref 与当前 HEAD，避免正常 pack-refs 先发布旧值再尝试 prune 的竞态；worktree 退役先写入带操作 UUID 的标准 `locked` 标记。源对象的持有身份在移动前、捕获后均复核，目标工作树与登记再做移动后的有界内容检查。应用目录清单的持久 sidecar lease 阻止合作写入者在修改期间改变保护范围。每个阶段在恢复目录记录原路径、登记路径及 commit，失败保留数据并显示恢复位置。

两个 rename 不是跨目录事务；程序崩溃／I/O 错误可能留下已移动文件和未移走登记，或恢复中的部分结果。应用不会自动猜测、继续或清空。保留 receipt 与目录，核对记录后人工恢复原位置，必要时再用 Git 的 repair 工作流。此处没有通用防恶意同用户并发写入保证，也没有「所有进程均未使用」证明；用户停止工具的确认与新鲜的有界复核不能替代内核级事务。

## 验证

纯 parser tests 包含由唯一临时系统 Git 仓库捕获的 index/tree 固定参考；helper tests 只使用 app-owned 合成仓库与固定测试程序。取消检查会阻止后续查询；一个已经运行的私有 Git 查询可能持续到 15 秒退出／超时边界，不把关闭 UI 描述成即时进程终止。Native fixtures opt-in 在 CI 的唯一用户主目录子文件夹中构建并执行真实退役、branch 移除和恢复；绝不对用户项目运行测试。覆盖 staged／untracked／ignored、独有提交、stale ref/index、锁、跨范围、符号链接、checked-out／主 worktree、packed refs、配置拒绝、重复确认和失败保留。

一手格式与命令资料：[index 格式](https://git-scm.com/docs/gitformat-index)、[Git 环境和全局选项](https://git-scm.com/docs/git)、[worktree 管理](https://git-scm.com/docs/git-worktree)。
