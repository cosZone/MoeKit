# 更新检查与应用入口

本页的菜单栏、独立图标设置和手动版本检查已随 [0.1.0-preview.9](https://github.com/cosZone/MoeKit/releases/tag/v0.1.0-preview.9) 交付；preview.8 不包含。精确源码、测试与下载验证见 [版本记录](../website/content/changelog/0.1.0-preview.9.md)。

[preview.10](../website/content/changelog/0.1.0-preview.10.md) 已交付 Sparkle 更新器与签名 feed，具体行为见 [自动更新](Automatic-updates.md)。preview.9 及更早版本仍需先手动安装本版一次。CI、自有视图渲染与合成更新 fixture 不替代真实用户生产安装、完整原生交互或权限迁移验收。

## 已实现的范围

- 菜单栏图标提供打开 MoeKit、设置、检查更新和退出；菜单项使用原生 AppKit target/action 和键盘等效键。应用菜单另有检查更新，Command-0 返回主工作区
- Settings → App icons 分别保存 Dock 和菜单栏图标的选择，默认均显示。两项互不隐式改变；同时关闭会显示恢复说明
- 图标均关闭时，从 Finder 或 Spotlight 再次打开 MoeKit 会重开已有工作区；Dock 重开也走同一路径，即使另有设置或关于窗口可见
- 关闭窗口不会退出应用，也不会因窗口消失而销毁共享工作区 store；分析、清理与确认等视图关闭时仍遵守各自的取消/撤销规则，不能承诺所有任务后台继续。打开/关闭设置不会启动扫描或清理

## 旧版与更新器不可用时的手动版本检查

以下是 preview.9 的手动检查行为，也用于当前构建中更新器未启动时的主动备用入口。正常 preview.10 的更新交互由下节 Sparkle 控制；签名错误不会自动切换到未签名安装路径。

- 检查更新仅由用户触发。读取固定的 cosZone/MoeKit 公开 GitHub Releases API，无认证、cookie 或持久网络缓存，不发送项目/任务数据；网络端仍会收到 IP 地址
- 请求有 15 秒空闲、30 秒资源时限和 1 MiB 响应上限；拒绝重定向、错误响应、错误 MIME、超大数据与分页不完整的列表。错误、限流、取消、空列表分别可见
- 预览版按数字比较，例如 preview.10 大于 preview.7，同一核心版本的正式版大于预览版；正式版默认排除预览，预览/开发构建默认包含预览，可切换渠道
- 发布包使用已存在的 MoeKitPreviewVersion 来源标识；不把省略预览后缀的 CFBundleShortVersionString 或工作流 run number 猜成完整发布版本。开发构建只报告所发现的最新发布版本，不谎称已是最新版
- 只打开由严格解析的版本号构造的本仓库发布页面。不会采用响应中的任意 URL、下载代码或覆盖应用；用户在浏览器手动下载、安装。它是手动版本检查，不是 Sparkle 自动更新
- 重复点击合并为一个在途请求；取消、关闭更新窗口或切换渠道立即撤销结果所有权，迟到响应不能覆盖新检查

MoePeek 的公开许可证为 AGPL-3.0；这里只参考“检查更新”和独立图标设置的产品行为，未复制其源代码。实现依据 AppKit / SwiftUI 的平台接口独立编写。

## preview.10 已交付的 Sparkle 更新

固定 Sparkle 2.10.0 由一个应用生命周期控制器服务应用菜单、菜单栏和 Settings。它负责下载、验证、安装与重启；本版的八份代码、双架构签名、生产 archive／feed 签名和公开下载已核实，详见 [发布记录](../website/content/changelog/0.1.0-preview.10.md)。

- preview.9 没有安装器，升级到本版仍需手动下载安装一次
- 标准第二次启动提示询问后台检查；自动下载安装默认关闭，开启后通常在退出应用时安装。检查／下载偏好与预览渠道单独保存
- 固定 HTTPS feed 与受审公钥；feed 必须签名，ZIP 必须在解压前验证，无定时未签名回退。配置无效或隔离启动时不启动更新器
- 原生修改／分析操作忙碌时拒绝为更新退出；替换应用包不主动清空包外的项目清单、偏好和恢复记录
- 构建顺序使用独立数字映射，preview.10 为 `2.0.10`；真实生产安装的后续更新、Gatekeeper、权限迁移和正式版频道仍需对应验收

维护者密钥边界、精确依赖／嵌套代码清单与发布门槛见 [Sparkle 发布契约](Sparkle-release-contract.md)。私钥配置仍由维护者控制；开发签名与未公证限制不变，不通过修改系统安全设置解决安装问题。

官方依据：
- https://sparkle-project.org/documentation/
- https://sparkle-project.org/documentation/publishing/
- https://sparkle-project.org/documentation/programmatic-setup/

## 验证边界与待人工检查

单元测试覆盖四种偏好组合持久化、缺省值、重开路由、重复安装、原生菜单 target/action 与合成 NSEvent 键盘等效键派发、delegate 关闭/重开事件路由、自有 status item 的创建/删除/重建、版本顺序、渠道、开发版本未知、限流/网络错误、取消/重开/迟到响应。测试用独立 UserDefaults suite 与合成网络响应，绝不访问真实项目或外网。URLProtocol fixture 经过真实 URLSession 字节流，验证无长度响应上限、重定向拒绝与取消；更新面板和双图标隐藏设置在英/简中及浅/深色渲染，artifact 检查要求取消、限流、未知开发版本等各状态及可见的隐私、手动安装、检查与恢复控件锚点。

- [ ] 两个开关四种组合，关闭全部窗口后从 Finder / Spotlight / Dock 恢复，再退出并重新启动核对偏好；同时隐藏时恢复说明可读
- [ ] 原生 Command-comma、Command-0、Command-Q、菜单栏键盘导航、VoiceOver、状态图标在挤满的菜单栏和多显示器下可用
- [ ] 任务进行中关闭主窗口，再打开后显示真实继续/取消/完成状态；关闭更新窗口立即取消该网络请求，不影响工作区任务
- [ ] 真实在线与离线手动检查、中文/英文、浅色/深色与发布页面导航；无新版本、发现新版本、限流及失败可重试

CI 的 target/action 检查不是实际按键、Launch Services 重启或 VoiceOver 测试；仍需上述原生验收，不可勾选为已通过。
