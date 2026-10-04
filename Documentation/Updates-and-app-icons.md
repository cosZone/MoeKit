# 更新检查与应用入口

本页描述源码；编译、测试和渲染是否通过以精确提交的 Native CI 为准，不把 Linux 源码检查或自有视图渲染当作人工原生交互验收。

## 已实现的范围

- 菜单栏图标提供打开 MoeKit、设置、检查更新和退出；菜单项使用原生 AppKit target/action 和键盘等效键。应用菜单另有检查更新，Command-0 返回主工作区
- Settings → App icons 分别保存 Dock 和菜单栏图标的选择，默认均显示。两项互不隐式改变；同时关闭会显示恢复说明
- 图标均关闭时，从 Finder 或 Spotlight 再次打开 MoeKit 会重开已有工作区；Dock 重开也走同一路径，即使另有设置或关于窗口可见
- 关闭窗口不会退出应用，也不会因窗口消失而销毁共享工作区 store；分析、清理与确认等视图关闭时仍遵守各自的取消/撤销规则，不能承诺所有任务后台继续。打开/关闭设置不会启动扫描或清理
- 检查更新仅由用户触发。读取固定的 cosZone/MoeKit 公开 GitHub Releases API，无认证、cookie 或持久网络缓存，不发送项目/任务数据；网络端仍会收到 IP 地址
- 请求有 15 秒空闲、30 秒资源时限和 1 MiB 响应上限；拒绝重定向、错误响应、错误 MIME、超大数据与分页不完整的列表。错误、限流、取消、空列表分别可见
- 预览版按数字比较，例如 preview.10 大于 preview.7，同一核心版本的正式版大于预览版；正式版默认排除预览，预览/开发构建默认包含预览，可切换渠道
- 发布包使用已存在的 MoeKitPreviewVersion 来源标识；不把省略预览后缀的 CFBundleShortVersionString 或工作流 run number 猜成完整发布版本。开发构建只报告所发现的最新发布版本，不谎称已是最新版
- 只打开由严格解析的版本号构造的本仓库发布页面。不会采用响应中的任意 URL、下载代码或覆盖应用；用户在浏览器手动下载、安装。它是手动版本检查，不是 Sparkle 自动更新
- 重复点击合并为一个在途请求；取消、关闭更新窗口或切换渠道立即撤销结果所有权，迟到响应不能覆盖新检查

MoePeek 的公开许可证为 AGPL-3.0；这里只参考“检查更新”和独立图标设置的产品行为，未复制其源代码。实现依据 AppKit / SwiftUI 的平台接口独立编写。

## 安全 Sparkle 后续集成（尚未启用）

用户仍需要真正的应用内更新。当前先交付可用的手动检查，不以不可用的 Sparkle 按钮冒充完成。

1. 维护者在自己可信的 Mac 使用固定版本 Sparkle 的官方 generate_keys 创建并保管 MoeKit 专属 Ed25519 密钥；只需向代码集成提供公开 SUPublicEDKey。不要把私钥发到聊天、提交仓库、打印到日志，或未经明确授权沿用 MoePeek 的私钥。若通过 GitHub Actions 签名，维护者本人通过 GitHub 安全界面存入专用环境 secret，并明确批准用途；自动化不读取或导出它
2. 确认一个维护者控制的 HTTPS appcast 地址及预览/正式渠道。使用 generate_appcast 生成归档 EdDSA 签名；若使用 Sparkle 2.9+，同时启用 SURequireSignedFeed 和 SUVerifyUpdateBeforeExtraction，并发布对应的签名 feed / notes，禁止无签名降级。公开 key、地址或签名缺失时不启动安装器
3. 固定经审查的 Sparkle 包版本和校验和，保留 Sparkle 及其依赖的许可证。按实际包内容逐个审核 framework、Updater.app、Autoupdate 与 XPC services 的 Mach-O 文件、bundle IDs、framework 符号链接及双架构；不能泛化现有拒绝未知代码/符号链接的发布规则
4. 扩展精确嵌套代码 allowlist 和由内到外的签名顺序，继续逐架构验证签名标识、证书、hardened runtime 和 entitlements；保留现有 Mole / Git 辅助程序规则，不使用 codesign --deep 代替签署清单，不关闭 library validation 或脚本沙箱。当前 Apple Development 签名与未公证限制必须继续如实说明
5. 建立独立单调递增的 CFBundleVersion 规则与渠道策略；不能将不同 workflow 的 run_number 直接混用。校验旧版本到新版本、preview.9 到 preview.10、预览到正式、渠道切换和禁止降级
6. 在无秘密的 PR CI 验证依赖、布局、双架构 archive、配置拒绝路径和伪造/篡改 feed/归档拒绝；签名发布 workflow 保持手动精确提交与受保护环境。授权配置后，在一次性 fixture App 上实际验证更新下载、签名、安装、重启、只读卷/Translocation、取消及失败恢复，之后才可启用真实安装

最小当前输入：维护者生成并提供 MoeKit 的公开更新 key，确认 HTTPS feed 地址，并自行配置受控签名 secret 的去向。没有这些输入时，安装仍保持未实现/未启用状态，不生成凭据、不改变访问权限。

官方依据：
- https://sparkle-project.org/documentation/
- https://sparkle-project.org/documentation/publishing/
- https://sparkle-project.org/documentation/programmatic-setup/

## 验证边界与待人工检查

单元测试覆盖四种偏好组合持久化、缺省值、重开路由、重复安装、原生菜单 target/action/键盘等效键、自有 status item 的创建/删除/重建、版本顺序、渠道、开发版本未知、限流/网络错误、取消/重开/迟到响应。测试用独立 UserDefaults suite 与合成网络响应，绝不访问真实项目或外网。URLProtocol fixture 经过真实 URLSession 字节流，验证无长度响应上限、重定向拒绝与取消；更新面板和双图标隐藏设置在英/简中及浅/深色渲染，artifact 检查要求取消、限流、未知开发版本等各状态及可见的隐私、手动安装、检查与恢复控件锚点。

- [ ] 两个开关四种组合，关闭全部窗口后从 Finder / Spotlight / Dock 恢复，再退出并重新启动核对偏好；同时隐藏时恢复说明可读
- [ ] 原生 Command-comma、Command-0、Command-Q、菜单栏键盘导航、VoiceOver、状态图标在挤满的菜单栏和多显示器下可用
- [ ] 任务进行中关闭主窗口，再打开后显示真实继续/取消/完成状态；关闭更新窗口立即取消该网络请求，不影响工作区任务
- [ ] 真实在线与离线手动检查、中文/英文、浅色/深色与发布页面导航；无新版本、发现新版本、限流及失败可重试

CI 的 target/action 检查不是实际按键、Launch Services 重启或 VoiceOver 测试；仍需上述原生验收，不可勾选为已通过。
