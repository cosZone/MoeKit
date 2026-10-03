# Git status：解析器已准备，执行仍关闭

## 本次已实现的边界

`GitStatusParser` 是无 IO 的纯字节解析器，读取完整、最多 2 MiB 的 Git porcelain v2 / NUL 输出。它不创建进程、不读取项目、不执行 Git，也不接受任意命令。现有源码执行禁令保持不变。

- 暂存、未暂存、未跟踪和冲突分别计数；同一路径同时有暂存与未暂存修改时，两项均计入，但修改路径总数只计一次
- 冲突单列，不再次计入暂存或未暂存；rename/copy 的第二个 NUL 字段是原路径，不是另一个状态记录
- 文件名按字节处理，空格、换行、非 UTF-8 字节不会破坏分隔；文件名不被解析为路径或命令，也不保存到结果
- 必需分支头缺失、重复字段/路径、截断、未知状态记录、格式冲突或超预算均拒绝；未知扩展头按 Git 合约忽略
- unborn、detached、无上游与没有可用 ahead/behind 比较是不同情况。`ahead`/`behind` 只比较**本地上游引用**，不证明提交已推送、远程可达或远端最新
- `GitStatusState` 区分未检查、不可用原因和带观察时间的结果，不以 `0` 代替失败；状态不写入 `ProjectRecord` 或持久目录

正常 UI 仍显示 **Not checked**。没有新增不可用按钮，没有启动时自动扫描，也没有清理资格或删除入口。解析器成功只说明输入符合约定，绝不验证其来源或一次运行是否安全。

测试包含手写恶意/边界字节及系统 `/usr/bin/git` 在唯一临时合成仓库产生的 8 组参考输出。`Scripts/capture-git-status-fixtures.py` 是开发用生成器；它只修改临时仓库与对应的测试文件，使用空 HOME、隔离配置、禁用协议的环境，不访问用户项目或网络。App 和 Swift 测试不会调用该生成器。

## 为什么不直接运行 git status

`git status` 并非天然的只读安全边界：默认可刷新并写回 index；fsmonitor 可启动程序；属性 filter 可执行仓库配置的命令；缺失对象可能触发 partial-clone lazy fetch；includes、用户/系统配置、继承的 `GIT_*`、追踪变量和子模块也可改变行为。

`--no-optional-locks` 仅抑制可选写锁；它不等于无副作用。`-c core.fsmonitor=false` 和最小环境也是防御层，不是对任意仓库配置的证明。先扫描危险配置再对原仓库运行，会留下配置替换与路径竞态。

将 `GIT_OBJECT_DIRECTORY` 指向原仓库同样不是隔离：Git 可读取其中的 alternates；先检查再读取仍会竞态。仅去掉 filter 或 attributes 配置还会改变比较语义，可能把用户平常的 Git 结果变成另一个结果。因此本次没有启用进程执行，也没有实现未验证的全对象复制引擎。

## 独立后续执行器的准入门槛（不是已实现功能）

首个可验证子集应限制为普通独立 `.git` 目录、SHA-1、files 引用后端、已知 plain index。下列情况一律保持明确的 unsupported / unavailable，除非后续实现及测试完整支持：

- gitfile、linked worktree、submodule/gitlink、bare、reftable、未知 repository format
- 配置 includes / includeIf、自定义属性来源、任何 filter driver、未知或影响比较语义的配置
- split/sparse index、未知 index 扩展、FSMN/UNTR 缓存、assume-valid、skip-worktree
- shallow、grafts、replace refs、promisor/partial clone、alternates/http-alternates
- 元数据符号链接、读取失败、目录/文件身份变化、超深/超量/超时的输入

拟议边界是 app 独占临时目录内的**独立普通文件快照**，不是 hardlink、symlink 或指向 live metadata 的环境变量。目录与文件的读取需 descriptor-relative/no-follow 打开并验证类型及身份；限定文件数、深度、总字节和复制时长，原始元数据变化须使结果失效。不能只用 Foundation 的预检查声称消除了 TOCTOU。

必须完整保留或拒绝影响比较的语义，覆盖工作树 `.gitattributes`、index fallback、`info/attributes`、ignore 文件及配置。即使元数据快照一致，正在修改的工作树也不是原子快照；不能由此给出“可删除”“已推送”或“安全”结论。

### 固定命令与环境草案

只允许固定受支持的系统 Git；不搜索 PATH，不安装工具，不接受可执行路径或命令字符串。`/usr/bin/git` 在 macOS 上的实际工具链解析及最低受支持版本也需本机验证。必须显式检查 `--no-lazy-fetch` 支持；该选项随 Git 2.45 引入，不支持则停止，不降级。旧版 fsmonitor 布尔语义也不能靠猜测。

状态 argv 仅包含预定义选项与经过身份验证的工作目录/私有 Git 目录参数：

```text
/usr/bin/git --no-optional-locks --no-lazy-fetch --no-pager --no-replace-objects
  --git-dir=<private snapshot> --work-tree=<explicit selected project>
  -c core.fsmonitor=false -c core.hooksPath=/dev/null
  -c core.untrackedCache=false -c protocol.allow=never
  -c submodule.recurse=false -c status.submoduleSummary=false
  status --porcelain=v2 -z --branch --untracked-files=all
  --ignore-submodules=all --no-renames
```

`--ignore-submodules=all` 不是支持子模块的证明；首个子集须提前拒绝 gitlink。禁止 silently override 属性/忽略配置然后宣称完整结果。

进程环境从空集合构建，仅加入受审查的固定变量：`LC_ALL=C`、app 临时 `HOME`/`XDG_CONFIG_HOME`、必要的固定 `PATH`、`GIT_CONFIG_NOSYSTEM=1`、`GIT_CONFIG_GLOBAL=/dev/null`、`GIT_CONFIG_SYSTEM=/dev/null`、`GIT_ATTR_NOSYSTEM=1`、`GIT_TERMINAL_PROMPT=0`、空 `GIT_ALLOW_PROTOCOL`、`GIT_OPTIONAL_LOCKS=0` 和 `GIT_NO_LAZY_FETCH=1`。禁止继承其他配置、askpass、ssh、trace、对象目录、动态库注入或开发工具选择变量。标准输入关闭。

应同时限制 stdout、stderr、运行时间、进程内存/CPU与解压对象预算；仅限制压缩对象大小和超时不足以防止内存耗尽。取消、超时和预算失败必须终止并回收**本次创建的子进程及其派生进程**，不能误向其他 PID 发信号，也不能遗留后台程序。该能力的实现必须单独接受执行边界审查。

### 激活前的本机对抗验证

1. fsmonitor、filter/long-running filter、hook、pager、diff helper、include/includeIf、恶意继承变量均放置无害 sentinel：不执行、不写入、不尝试网络
2. 缺失对象、promisor、alternates、shallow、replace、grafts、linked worktree、子模块及所有不支持 index 变体，均明确拒绝
3. 普通、暂存+未暂存、rename、换行/非 UTF-8 文件名、unborn、detached、冲突、本地上游缺失或分叉与系统 Git 的预期输出一致
4. 并发替换 config/HEAD/index/refs/object/目录、symlink 和元数据被删，不能交付成功结果或越出授权目录
5. 比对原目录 metadata 内容与身份：没有 index、锁、对象、引用或日志写入；无自动 fetch 或工具安装
6. 不支持的系统 Git、缺失工具链、stdout/stderr 洪泛、阻塞 IO、超时、取消及派生进程回收有原生测试证据
7. MainActor coordinator 使用请求 generation 与项目 ID/path 身份绑定；重复请求、选中项目变化、取消、Demo 进入/退出与目录刷新不接收旧结果
8. UI 标为带时间的有限观察；失败不显示零/clean，旧值不冒充刷新成功；本地 ahead/behind 明确不代表远端状态；清理仍不可执行

完成独立实现审查、精确提交的 macOS CI 与上述本机证据之前，不开放真实项目执行。

## 一手资料

- [Git status porcelain v2、NUL 与后台 index refresh](https://git-scm.com/docs/git-status)
- [Git 全局选项与环境变量](https://git-scm.com/docs/git)
- [Git config：includes、fsmonitor、filter 与配置作用域](https://git-scm.com/docs/git-config)
- [Git attributes 与 filter 语义](https://git-scm.com/docs/gitattributes)
- [Git index 格式与扩展](https://git-scm.com/docs/gitformat-index)
- [Git 2.45 发布说明：no-lazy-fetch](https://github.com/git/git/blob/master/Documentation/RelNotes/2.45.0.adoc)
