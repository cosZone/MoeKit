# GitHub Actions 开发签名预览

此流程交付供作者／测试者试用的 **DMG 与 ZIP**，两者包含同一份已签名 `MoeKit.app`，并创建明确标为 prerelease 的 GitHub Release。它使用现有 **Apple Development** 证书，**不是 Developer ID 分发签名，也没有 Apple 公证**。DMG 只是安装容器，不改变签名或 Gatekeeper 的限制；macOS 仍可能阻止打开。不要把“有效签名”理解为“苹果已审核”或“任意 Mac 均可直接运行”。正式对外分发应另行配置 Developer ID 与公证；本流程不包含绕过系统安全检查的命令。

## 一次性准备：由仓库所有者直接配置 Secrets

凭据只由所有者在 GitHub 的安全表单中输入；不要放进聊天、Issue、PR、源码、工作流输入或构建产物。现有 P12 必须包含证书及其配套私钥，仅 `.cer` 不够；P12 使用非空密码保护。

推荐把以下三个值创建为 **cosZone organization Actions secrets**，Repository access 选择 **Selected repositories** 并选中 `MoeKit`；如果希望与 MoePeek 共用，同时选中 `MoePeek`：

- `SIGNING_CERTIFICATE_P12`：包含恰好一个有效 Apple Development 签名身份的 P12 文件的 base64 文本
- `SIGNING_CERTIFICATE_PASSWORD`：该 P12 的非空导出密码
- `DEVELOPMENT_TEAM`：证书所属的 10 位 Apple Developer Team ID

入口：[cosZone → Settings → Secrets and variables → Actions](https://github.com/organizations/cosZone/settings/secrets/actions)。也可在 [MoeKit repository Actions secrets](https://github.com/cosZone/MoeKit/settings/secrets/actions) 中使用同名 Repository secrets，仅对 MoeKit 生效。不要在普通 Variables 中保存这些值。

MoeKit 工作流直接读取上述三个名字，**不要求创建 `Prod` environment**。MoePeek 既有 `Prod` environment secrets 保持原样；environment 同名值优先于 repository／organization 值，因此增加组织级值不会自动替换 MoePeek 的现有签名值。不要为“同步”而导出、复制或删除现有隐藏值。

工作流只报告缺失的 secret 名字，不显示内容；缺失、空密码、P12 无效、身份数量不为一、证书过期、身份类型错误或 Team ID 不匹配都会阻止签名与发布，不会退回 unsigned/ad-hoc 发布。自动更新另需所有者配置的 `SPARKLE_ED_PRIVATE_KEY` 与受审公钥，详见 [Sparkle 发布契约](Sparkle-release-contract.md)；不新增 Apple 公证凭据。

签名证书的公开部分会随正常代码签名进入 `.app`，其中可包含签名者名称和 Team ID；私钥、P12 和密码不会进入交付包。任何真实签名软件都不能把公开证书身份当成隐藏信息。

## 审核并合入后才运行

1. 审核 `.github/workflows/preview-release.yml`、`Scripts/preview-release.py`、测试与应用源码，并合入默认分支。GitHub 的手动 workflow dispatch 需要默认分支存在该工作流。不要临时改成 PR／tag 自动触发来绕过这一步
2. 确认默认分支的实际 40 位 commit SHA，查看该提交的 CI 结果。通过 Actions 打开 **Signed preview release**，选择默认分支
3. 在同一受审提交中准备 `website/content/changelog/<version>.md`，然后输入 `version`，例如 `0.1.0-preview.2`，以及完整 `source_sha`。版本不带 `v`，只允许 `数字.数字.数字-preview.数字`，不接受任意 ref、shell 文本、稳定版号或其他后缀
4. Workflow 的源 SHA、checkout SHA 和填写的 SHA 必须一致。默认分支已前进时应重新审核新的 HEAD 后填写它，不能通过指定旧分支／tag 绕过
5. 查看 build-and-test、sign、publish 三个 job 的结果；只有全部完成后才把 Release 视为已交付

最终 tag 与 Release 名称均为 `v<version>`，例如 `v0.1.0-preview.2`，精确指向填写并验证过的提交；始终 `prerelease: true`，不会成为 latest 正式版。版本示例只是格式示例，不表示该版本已发布。既有 preview.1 的 tag、正文与资产不会改变。

## 构建与交付内容

- macOS 15 runner、Xcode 16.4、Tuist 4.148.3；各 action 固定到完整 commit SHA
- 无私有签名 secrets 的独立 job 运行 Release 配置单元测试（`ENABLE_TESTABILITY=YES`），随后从相同源码单独 archive universal Release；测试只运行 runner 的当前 CPU 架构
- 归档 `.app` 同时包含 arm64、x86_64，Bundle ID 固定为 `com.yusixian.MoeKit`，最低 macOS 15.0
- 签名 job 不编译源码、执行应用或运行第三方安装器；它只验证同次 run/attempt 的产物，用临时 keychain 内唯一的 Apple Development 身份重新签名，核对证书指纹、预期 Team ID、两种架构、bundle 信息与 provenance
- Hardened Runtime 开启；无额外 entitlements、无 get-task-allow、无 App Sandbox、无 provisioning profile。preview.14 源码包含四个显式列出的原创辅助程序 `Contents/MacOS/MoleAnalysisSupervisor`、`Contents/MacOS/GitObjectInspector`、`Contents/MacOS/GitRemoteTransport` 和 `Contents/MacOS/OperationTerminal`，标识分别固定为 `com.yusixian.MoeKit.MoleAnalysisSupervisor`、`com.yusixian.MoeKit.GitObjectInspector`、`com.yusixian.MoeKit.GitRemoteTransport` 和 `com.yusixian.MoeKit.OperationTerminal`；本版核对十份代码对象。历史 preview.10／preview.11 为八份，preview.12／preview.13 为九份；另允许固定 Sparkle 2.10.0 框架及其四个精确嵌套 helper，仅允许官方 manifest 的精确相对链接。其他 helper/framework/XPC 与可执行资源一律拒绝
- 先用同一个现有 Apple Development 身份显式逐个签名四个原创 helper、Sparkle 的四个嵌套 helper、Sparkle.framework，再签名父 App；不使用 `--deep` 签名或继承旧 entitlements。十份代码每个 arm64／x86_64 slice 均验证精确标识、Hardened Runtime、空 entitlements、Apple trust anchor、预期 Team ID 与导入证书指纹；ZIP 往返与 DMG 内再次逐个核验代码，全部文件内容（含 helper 与签名）必须相同
- 这四个 helper 均由本仓库原创 C 源码构建；`OperationTerminal` 负责固定 Homebrew Mole 升级操作的 PTY 与进程组监管。第三方 Mole 分析器和 Apple Git 不随 App 分发，不进入发布签名流程，也不会被重新签名；发布 allowlist 显式拒绝额外的 `Contents/MacOS/git`
- SwiftTerm 1.20.0 静态链接；其唯一资源包 `Contents/Resources/SwiftTerm_SwiftTerm.bundle` 仅包含 `Contents/Info.plist` 和 `Contents/Resources/default.metallib`，不属于上述十份可签名代码对象。资源包不得声明 `CFBundleExecutable`，资源文件不得有可执行权限或 Mach-O 内容，不允许符号链接及额外文件；Metal 资源必须具有 `MTLB` 标识
- 不使用公证或安全时间戳；证书过期／撤销可能影响后续校验。代码签名并不承诺长期分发可用性
- Release 精确包含五个文件：`MoeKit-v<version>-macOS.dmg`、`MoeKit-v<version>-macOS.zip`、`SHA256SUMS.txt`、`BUILD_INFO.json`、已签名 `appcast.xml`。两种安装包均为 universal，包含 arm64 与 x86_64；不另发芯片专用包
- ZIP 中是 `MoeKit.app`（如有 `ditto` 的 AppleDouble 元数据，只允许对应 App 的数据）；DMG 根目录严格只有 `MoeKit.app` 和指向 `/Applications` 的 `Applications` 快捷方式，不包含 App 之外的安装器或其他可执行文件；Sparkle 更新组件位于受审 App 内
- `SHA256SUMS.txt` 覆盖 DMG、ZIP、`BUILD_INFO.json` 与 `appcast.xml`。构建信息包含两种包各自的 SHA-256、App 内逐文件内容摘要（包括代码签名文件）、版本说明原文件摘要、源码／工作流运行链接、工具链、架构与验证边界；不写入 Team ID、个人身份文本或任何 secret 值
- `.app/Contents/Info.plist` 在签名前写入同样的源码 SHA、预览版本与 run/attempt，用于交叉核对最终文件确实来自此构建
- 测试结果单独保留 14 天；unsigned 中间产物仅用于 job 间传递，保留 1 天，不发布到 Release；signed Actions 产物保留 14 天

`.app` 的版本号使用 `0.1.0` 这样的数字部分，完整 preview 版本单独保存；build number 来自 [受限的数字语义映射](Sparkle-release-contract.md)，Actions run number 只作为独立 provenance。

### DMG 创建与只读验证

先签名 App，再用系统 `ditto` 生成并往返解包 ZIP；从已验证的 ZIP App 准备 DMG。只使用 macOS 内置 `hdiutil create -srcfolder`，显式设置 HFS+ 与 UDZO 压缩格式，不安装 `create-dmg`，不运行 Finder AppleScript，不修改 TCC 或 quarantine。任何非零退出码都失败，不接受“退出 1 也算成功”。DMG 容器本身未单独签名；验证的是它内部的 App 签名。

`hdiutil verify` 检查镜像的内建校验和，随后在脚本独占的固定临时挂载点以 `-readonly -nobrowse -noautoopen -verify` 挂载。脚本还核对实际挂载状态与只读文件系统标志、精确根目录、Applications 链接、双架构、bundle 与构建来源、App 内全部常规文件的路径和内容摘要，以及所有架构的严格代码签名。初次验证的已签名 App、ZIP 解包后的 App 与 DMG 内 App 内容须一致。这里的镜像校验不等于实机启动测试或完整文件系统修复检查。

挂载点位于签名临时目录之外。正常、失败、部分挂载和超时路径均通过 `finally` 尝试 detach；工作流的 `always` 清理会再次检查。不会 force-detach；卸载失败会阻止发布并保留独立挂载目录供 runner 销毁，同时仍清除签名凭据。挂载点只允许 `rmdir`，绝不递归删除它或一个可能包含它的父目录。

`Scripts/test-preview-release.py` 包含无需凭据的 macOS 集成测试：用 Xcode 编译十个合成的 universal code objects，按 helper → App 顺序 ad-hoc 签名后实际执行 ZIP／DMG 创建与只读校验，最后验证卸载；另检查 helper 标识错误、缺少 runtime、额外 entitlements、篡改、缺少架构和未签名均失败。**不执行这些程序**。它随 Native CI 与发布的无 secrets 测试阶段运行，Linux 上显式跳过。便携单元测试不能代替这项原生验证。

### 版本说明的唯一来源

发布正文读取同一提交中的 `website/content/changelog/<version>.md`。这是普通 Markdown，不执行 MDX／HTML 组件或仓库脚本。开头用精确的 `---` 围住小型 frontmatter：必需 `title`、`version`、`description`（单行双引号字符串）与 `status: unreleased`。版本必须与 dispatch 输入一致；文件缺失、正文为空、重复／未知字段、嵌套值、块文本、别名或 YAML 标签都会在签名前阻止发布，不新增 YAML 依赖。

发布成功并人工核实前保留 `unreleased`，不提前写入 `date`、`sourceCommit` 或 `releaseUrl`。成功之后可在独立文档变更中使用 `status: prerelease` 与核实后的日期、源码提交和 Release 链接；发布日期采用引号内 UTC `YYYY-MM-DD`，源码为 40 位小写 SHA，链接是本仓库该版本的 Release。发布脚本不自行修改或提交版本说明。

GitHub 正文只包含 DMG／ZIP 下载、原样保留的版本说明和精简的源码／构建／校验和链接。说明中已写明的 macOS 15+、Apple Development 与未公证提示不会重复追加；缺少时补一行共同限制。详细验证与人工验收边界放在构建信息和开发者记录中。appcast 仍使用原始受审说明及独立 Ed25519 签名，展示文案调整不改变发布、签名或资产校验。

编辑已发布版本的展示说明时，先在 `website/release-records/<version>/` 保留签名时的原始 Markdown、最初生成的 GitHub 正文及哈希来源；展示说明不能冒用旧文件摘要。历史资产、tag 和已签名 feed 保持原样。

## 权限、清理与失败处理

- 只有手动 dispatch，限本仓库默认分支；源码和 workflow 均绑定到同一完整 SHA。所有输入通过环境变量传入并作白名单校验，不插值为 shell 程序
- build/sign token 只有 contents read；只有 publish job 有 contents write；同一 job 在不可变 Release 验证后，非 force 更新仅含 appcast 的专用 updates 分支。Apple 与 Sparkle 私有签名 secrets 仅在 sign 的一个步骤注入，不提供给 Xcode、mise、测试或发布 job
- P12 仅写入 runner 临时目录，导入后立刻移除；临时 keychain、证书校验副本和临时展开目录通过 finally 加 always 清理。独立 DMG 挂载点遵守上述非递归卸载边界。上传列表逐个列明，只接受 DMG、ZIP、校验和、安全构建信息与已签名 appcast
- 没有 `pull_request_target`、PR secrets、持久凭据、自动创建 Apple 凭据或远程配置修改。不要在含真实凭据的任务中启用命令追踪、打印环境、上传整个 workspace 或改变白名单上传路径
- 并发按仓库预览发布串行化，后来的 dispatch 不会取消已开始的签名／上传
- 已有 tag 若指向其他 SHA，立即停止，绝不移动 tag。已有同 tag 的已发布 Release **或 draft** 一律停止，不覆盖／删除其资产
- 新 Release 先创建为 draft，逐个上传并核对服务端 SHA-256，再确认 tag 未变，最后转为 prerelease。失败时可能留下 tag 和／或 draft，便于检查；不会自动删除它们，也不会把半上传结果当成功
- **在尚未创建 Release/draft 的阶段失败**，修复原因后选择 **Re-run all jobs** 或重新 dispatch。不要只选 Re-run failed jobs：产物名称与 provenance 绑定 run attempt，旧 attempt 的产物不能用于新的 signing/publishing attempt
- **已留下 Release/draft 时**，先手动审核其内容再决定恢复方式，或选择新的 preview 版本重新 dispatch。此脚本不自动恢复、覆盖或删除已有 Release

默认分支校验是此受审工作流的防误用措施，不能约束有权限修改其它工作流的恶意仓库写入者。必须仅向可信协作者开放写权限，并保护默认分支／发布脚本的修改；organization secret 的 Selected repositories 决定仓库可用范围。需要更强的审批隔离时，应另行设计受保护 environment，不要认为代码中的分支判断等同于 GitHub 的服务端 secret access policy。

### 签名失败的安全诊断

本流程只公开固定操作名称、数字退出码，以及 `temporary_keychain_in_search_list=true/false`；不公开命令参数、路径、身份、环境变量或原始输出。`codesign-sign` 失败时，会从捕获的 stderr 匹配固定白名单，输出所有匹配的类别：证书链／有效期、钥匙串交互／身份访问、bundle 元数据／结构、可执行文件格式、文件访问、工具参数或内部安全错误；没有匹配时输出 `unclassified`。类别是排查线索，不是已确认原因；`security-internal` 尤其不能直接断言为密码、证书或权限问题。

本应用使用 SwiftUI App 生命周期，构建与产物检查拒绝 `NSMainStoryboardFile`／`NSMainNibFile`，防止打包时引入并不存在的主 storyboard／nib。此检查保证入口配置与源码一致；不代表此前已证实启动故障，也不能代替真实启动验收。

签名前，将临时签名钥匙串加入当前用户的搜索列表，同时逐项保留原列表及其顺序，再只读核对临时钥匙串是否在列表中；若仍缺失则停止签名。临时项置于原列表之前，现有 finally／always 清理恢复保存的原列表。不改变默认钥匙串、信任或私钥访问控制。有效身份可被显式找到，不代表它已在 `codesign` 使用的搜索列表中；注册与 membership 检查补齐这一前置条件。其余诊断仍只提供排查线索，不会自动扩大密钥访问、清除属性、替换证书或降低签名验证，也不改变 `.app`、发布资产或上传白名单。

依据：[Apple 的非交互代码签名排查](https://developer.apple.com/forums/thread/712005)、[签名证书与证书链](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)、[bundle 扩展属性签名限制](https://developer.apple.com/library/archive/qa/qa1940/_index.html)。

## 安装与后续版本身份

下载前对照 Release 的 exact source/run 链接，并用 `SHA256SUMS.txt` 检查下载文件。推荐下载 DMG，打开后将 `MoeKit.app` 拖入 `Applications`；也可下载 ZIP 并解压取得同一份 App。按 macOS 的正常安装／安全提示处理。若系统拒绝打开，此开发预览并不保证可安装；不要通过关闭 Gatekeeper、删除 quarantine 或重签成 ad-hoc 解决。

固定 Bundle ID 与一致的开发团队有助于版本身份连续性，但**不保证 TCC／辅助功能／文件访问等授权在更新后沿用**。签名类型、证书链、designated requirement、系统版本、安装位置和权限范围变化均可能影响系统判断。未来从 Apple Development 转为 Developer ID 时须实际测试权限迁移，不能提前承诺“不再弹权限提示”。

首次 release 仍需真实 Mac 检查启动、导航、文件夹选择、扫描取消、Demo 切换、VoiceOver 以及两种架构的运行。CI 单元测试和签名校验不能代替这些验收。

## 参考依据

- [MoePeek 已有 release workflow（审查时固定提交）](https://github.com/cosZone/MoePeek/blob/f12d42122ae3129177cf7d8ce78ca0a910d419d7/.github/workflows/release.yml)：沿用 secret 命名；没有照搬输入插值、宽权限或可变 action tag
- [MoePeek v0.20.0 release workflow](https://github.com/cosZone/MoePeek/blob/v0.20.0/.github/workflows/release.yml)：参考 DMG／ZIP 命名、Applications 拖放入口与版本标题；未复制 create-dmg 的退出码宽容、PopClip 或 Sparkle 流程
- [Apple 磁盘映像说明](https://support.apple.com/guide/disk-utility/create-a-disk-image-dskutl11888/mac) 与 [Apple 软件分发打包](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)：文件夹镜像与只读安装容器；精确命令选项以固定 macOS runner 的 `man hdiutil` 为准
- [Apple 代码签名 requirement 语言](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)：精确 identifier、Apple anchor、leaf certificate 指纹与 Team ID 条件
- [GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use)：输入隔离、最小权限、固定 action SHA
- [GitHub Actions secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)：组织／仓库／environment secrets 与访问范围
- [GitHub release asset API](https://docs.github.com/en/rest/releases/assets)：上传及 SHA-256 digest 校验
- [Apple Developer ID](https://developer.apple.com/developer-id/) 与 [macOS 分发签名](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)：开发签名、公证、正式分发和隐私授权身份之间的边界
