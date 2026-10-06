# AI worktree 收尾：本地合并、复核和独立退役

这是后续源码功能，不属于 preview.10 或 preview.11 的发布范围。AI 的「完成」消息不是文件已保存、提交已合并或测试已通过的证据。

## 支持的本地流程

从一个已导入的 linked worktree 的 Git cleanup → Finish AI worktree 进入，选择包含主仓库与 source worktree 的共同父目录，以及一个已存在的本地 target 分支。

1. **检查**：读取 source/target 精确 OID、source 独有提交数、index 与 committed tree 是否一致、modified tracked 文件及所有额外文件/目录。没有执行 ignore 规则，因此 untracked 与 ignored 合并统计且全部受保护，不能把 ignored 的未知分类显示为零。项目测试始终明确显示为未由 MoeKit 执行；不运行仓库提供的测试脚本。
2. **确认本地 fast-forward**：目标必须是 source 的祖先。支持未被检出的 local target，也支持在主 worktree 检出的 target（通常为 main），后者必须完全 clean。用户确认关闭两边的编辑器、终端和 Git 操作，并输入精确 target 分支名。包括 main 在内的所有 target 均需要本次人工确认。
3. **执行和复核**：原生文件操作更新目标 checkout/index/ref，再检查精确 target OID、index tree 和文件字节。source 及其分支不删除。合并不是测试通过的证明。
4. **远端**：输入精确 HTTPS URL 与现有远端分支，并先同意该目标的网络/既有 Keychain 凭据访问。inspect 显示当前远端 OID；用户再输入精确 `refs/heads/<branch>`，授权本次 source OID → URL/ref/expected-old-OID 推送。推送后另一次独立读取须观察到精确 source OID 才显示 verified。远端选择可不同于本地 target 分支。
5. **独立退役**：返回 Git cleanup 的新表单，重新 inspect，然后另行确认退休 source。沿用现有可恢复退役，不自动删除 source 分支，不删除远端分支，不释放磁盘空间。退役的确认与 push、本地 merge 的确认互不替代。

没有 non-fast-forward 自动合并、merge commit、rebase、stash、reset、force push 或冲突解决。分支分叉时显示 blocker，并保留两边工作。已完全包含的 source 不需要重复合并，可回 Git cleanup 单独检查退役。

## 普通仓库子集

继承 [Git 整理](Git-cleanup-design.md) 的有界 SHA-1、files refs、plain index v2 和 ordinary 100644/100755 文件限制。source 必须是登记一致的 linked worktree；target 若被其它 linked worktree 检出则拒绝。source/target 必须有已存在的 loose ref，若相同分支还存在于 packed-refs 也拒绝；不会重写无关 packed refs。所有路径逐级 no-follow，拒绝不可信 ACL、cloud attributes、跨卷、只读/非本地卷、符号链接、submodule/gitlink、attributes/content filters、配置 includes、未知 index 扩展和正在进行的 Git operation。

Native 操作不会运行 source 或 target 仓库里的配置、hooks、filters、脚本、测试或 signing program。fast-forward 直接保留原 commit OID，因此已有签名提交不被改写，也不声称验证签名信任。对象关系仍由临时复制且验证 Apple 签名的已安装 Git，在 app-owned、configuration-free 对象副本内检查；新增固定操作仅为 `rev-list --count <source> ^<target>`。相关 argv 仍只接受固定枚举及 40 位小写十六进制 OID。

## 一致性和恢复

确认后在 `.git/moekit-recovery/finish-<UUID>/` 创建私有分阶段记录、`previous/` 和 `staged/`。用于 target checkout 的新文件仅来自已逐字节验证的 source capture，普通文件以 0600、executable 以 0700 创建，目录 0700；Git 内容和可执行位保持一致，权限不会扩大。全新的 v2 index 清空 source stat cache；Git 必须重新检查 materialized 文件。

持有 source/target loose-ref lock、packed-refs lock、source 登记的 HEAD/index lock，以及 primary target 的 HEAD/index lock。每次关键提交前重新检查控制文件、锁的 descriptor/named identity 和期望的旧 ref。合作 Git 写入者需使用相同标准锁名；这些锁不能阻止普通编辑器或恶意同用户程序写文件。

primary target 的每个 top-level tracked 文件/目录先以同卷独占 rename 移入 previous，再把 staged 内容以独占 rename 移入 target；`.git` 不移动。移出的旧文件在继续前验证身份和字节。旧 index 与 ref 独占移入 `previous-index` / `previous-ref`，新 lockfile 再原子命名为 index/ref，目标存在时拒绝覆盖。source 一直保留。未 checkout 的 target 仅执行 ref 阶段。记录精确前后 OID，不自动改写 Git reflog；恢复记录不是独立 object bundle，也不替代备份。

**这是有保留数据的多步骤操作，不是 filesystem transaction。** crash、取消、I/O error 或并发变更可留下部分应用。发生 live 更改后若未完成，保留剩余本次标准 lockfiles，并写 `retained-partial` receipt 列出它们；不得把锁当作任意「旧锁」删除。错误展示恢复路径。不要编辑、执行 reset/clean、删除恢复目录或自动重试；先核对 receipt、原路径、旧 index/ref 和实际文件，使用 Git 客户端进行人工恢复。没有自动 rollback，因为不能覆盖后来新增或修改的数据。初始化不扫描 journal、不恢复、不清理任何历史数据。

计划为 session-bound、120 秒单次授权。改变 source/target、退出 review、切换 Demo 或更新目录清单会废弃计划；若操作已经发生，session 记录仍保留结果/恢复路径，但不能作为新的操作授权。忙碌状态阻止 Sparkle 为安装更新而退出应用。

## HTTPS transport 与凭据边界

远端流程不会读取仓库 remote/helper/URL rewrite/proxy/hook 配置，也不会使用 global/system Git 配置、继承 GIT_*、proxy、DYLD 或 trace 环境。只接受小写 ASCII DNS 主机和简单 ASCII 仓库路径的 HTTPS URL；不支持用户名/密码、端口、转义、query、fragment、IDN/punycode、IP literal、本地域或重定向。仅存在的 `refs/heads/` 分支；不使用 wildcard、删除/force refspec、fetch 或自动新建分支。local source/target 必须仍指向先前已验证的提交且内容 clean；远端旧 OID 必须存在于本地对象副本且可证明为 source 祖先，缺少对象时请先用 Git 客户端处理。

运行副本仅含 app-owned Git 对象、固定 bare config 和原生 gate。使用已安装 Apple Git、git-remote-https（允许从固定普通文件 git-remote-http 复制）和 git-credential-osxkeychain，分别验证 Apple 签名，Git digest/version 必须与 inspector 一致。支持固定 CLT、Xcode.app、Xcode_16.4.app 布局，缺少工具或仅有不支持的符号链接布局会拒绝。安装器不捆绑或下载这些 Apple 工具。

随 app 捆绑的原创 `GitRemoteTransport` 先绑定到运行中 app 及其 nested-code seal，再复制为 supervisor、固定 `hooks/pre-push` gate 和固定 credential wrapper。**仓库 hooks 禁用，但 app 自己的原生 gate 会使用 Git 的 pre-push callback。** 它验证仅一条记录及精确 URL/ref/source/advertised-old。随后是 ordinary non-force push；Git server 的 expected-old compare-and-swap 仍生效，没有 `--force`、`--force-with-lease` 或 `--no-verify`。因此 inspection 后或 server advertisement 后的改动均不能悄悄替代获批目标。

**Git 内部可能用 shell 分派固定 credential helper，此处不宣称所有后代都无 shell。** App 不接受 shell 字符串、用户命令或仓库 helper。原生 wrapper 只接受 Git 对批准的 HTTPS host/path 的 `get`，再以同一主机查询现有 host-scoped macOS Keychain 项，避免普通已登录 Git 的 host-only 凭据无法使用；凭据仅返回给批准 URL 的 HTTPS 传输。`store`/`erase` 不产生 Keychain 写入。密码输入、askpass、终端 prompt 与 redirects 关闭；系统 Keychain 是否需要交互许可由 macOS 决定，未获准/未知访问会停止，app 不绕过授权。不展示或记录凭据以及原始 Git/server stderr/stdout。此操作会把 source 提交及可达历史发送到显示的仓库，必须在推送确认中明确这一数据分享。

supervisor 对此次拥有的进程实施 60 秒 wall、20 秒 CPU、direct-Git 512 MiB RSS watchdog、4096 B stdout、64 KiB 被丢弃的 stderr、零文件增长预算和继承 descriptor 关闭。它不是 OS sandbox，也不声称进程树总内存硬上限。检查结果仅输出精确 OID/ref，push 原始输出不返回 UI。stdout EOF 后有界等待本次 helper 真正退出；未确定退出时保留对象副本，不能启动重叠请求。

推送命令成功或失败均不能独自证明服务器结果。之后独立 ls-remote 分为精确提交已观察、仍为旧提交、其它提交或未知。未知/不同结果保留 worktree，不自动重试；用户可单独批准只读 reconcile，不再发送 push。已选择远端步骤时，GUI 必须观察到精确 source OID 才开放独立退役表单。该观察并未锁住远端，不检查 CI、PR 审批或远端保护策略是否满足。

## 验证证据

- Portable C helper fixtures 验证 private object-only argv、环境、deadline、输出预算、取消和 exact unique-commit count；这不是 Swift 编译
- 新增 Swift authority/store 测试覆盖 typed target、closed-tools、one-use、expiry、Demo、stale inspection、操作完成/失败后的恢复记录
- Native opt-in fixture 使用唯一、marker/identity-owned 的用户主目录下临时仓库，真实 Git 验证 primary fast-forward 后的 ref、文件、index 和 clean status，并独立执行退役/恢复；另覆盖未 checkout 的 target、分叉、dirty/staged/ignored、packed refs、filter/config、symlink、stale plan 和 partial retention
- Portable transport fixtures 使用原创 compiled relay 与自有 bare 仓库，验证真实 Git non-force 更新、advertised-old gate 与 server CAS 竞态拒绝、恶意 config、URL/ref/host 注入、get-only 凭据协议和输出抑制；不访问真实 Keychain/凭据/公开远端，不验证 TLS、真实服务或 macOS signing
- Linux 环境不能证明 macOS 编译、Swift 测试、原生 GUI 或真实权限工作；精确 head 的 macOS CI 和人工 GUI 验收必须分别记录通过/失败/未执行
