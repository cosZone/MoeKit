# Sparkle 更新发布契约

当前源码固定 Sparkle **2.10.0**，Git revision `eef1a539a373c1f1a320624b1130fc5de7b2e100`。官方 SPM ZIP 的 SHA-256 为 `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`。`Configurations/Sparkle.json` 是版本、公钥及 feed 地址的受审来源；`Sparkle-layout.json` 记录同一官方包逐个文件、链接和原始摘要。更新框架不是 Mole 或 Apple Git，后两者仍不随 App 分发。

## 所有者的一次性配置

1. 使用该官方 Sparkle distribution 的 `bin/generate_keys` 在自己的安全环境创建长期 Ed25519 更新密钥，妥善备份。公开输出的 **32 字节公钥 base64** 提交到 `Configurations/Sparkle.json` 的 `publicEDKey`，随代码审核；并由所有者在 Actions Secret **`SPARKLE_ED_PUBLIC_KEY`** 输入完全相同的字符串。沿用 MoePeek 的 Secret 名称与来源，公钥本身不是密码；每次发布先核对 Secret 中的公开值与受审公钥完全一致，不能用 CI 值替换源码公钥。
2. 私钥由所有者直接输入 GitHub Actions secret **`SPARKLE_ED_PRIVATE_KEY`**，仅授权 `cosZone/MoeKit`。内容是 Sparkle `generate_keys -x <private-file>` 导出的 base64 文本，通常解码为 32 字节 seed；兼容旧的 96 字节导出。不是 P12、PEM、JSON，也不需要再次 base64 编码。
3. 私钥不要发进聊天、Issue、PR、源码、普通 Variables 或 workflow inputs。保留现有 Apple Development 三个 secrets；更新密钥与 Apple 代码签名证书用途不同。助手不会读取、生成或配置生产私钥，也不会修改账号或仓库权限。

公钥为空时更新器保持未配置状态；公钥 Secret 缺失或与源码不一致时正式发布校验停止。私钥缺失、格式不合法、与公钥不匹配或签名验证失败同样停止，不发布 unsigned feed，不退回缺少签名的更新。启用公钥后需要新安装包；既有 preview.9 或更早安装包不包含这个更新器。

## 精确框架与代码签名

保留官方完整框架，包含 `Versions/B/Sparkle`、`Autoupdate`、`Updater.app`、`XPCServices/Installer.xpc`、`XPCServices/Downloader.xpc`。MoeKit 不启用 App Sandbox 或两个可选 XPC service 开关。标准 Xcode copy 阶段可省略开发 Headers、PrivateHeaders、Modules；其余运行内容必须齐全。只允许 manifest 内精确相对链接，例如 `Versions/Current → B`；不接受绝对链接、额外版本、重定向目标、隐藏 executable 或其他 framework。

无 secrets 的归档与签名前分别核对 vendor 原始字节，且 `COPY_PHASE_STRIP=NO`。签名后不再要求原始签名字节相同，改为全文件及符号链接目标摘要、逐对象严格代码签名、ZIP 往返及只读 DMG 核验。

受审签名顺序为两个原创 helper、Installer.xpc、Downloader.xpc、Autoupdate、Updater.app、Sparkle.framework、MoeKit.app。八个对象均使用同一导入身份，逐个验证 arm64 与 x86_64、固定 identifier、Hardened Runtime、空 entitlements、Apple anchor、证书指纹与预期团队。不使用 `--deep` 或继承未知 entitlements。上游 Autoupdate 的 application-identifier entitlement 在显式重签时不继承，这与官方手动重签说明一致。App 仍是 **Apple Development、未公证**；Sparkle 不改变 Gatekeeper、安装位置、授权迁移或正式分发限制。

## 版本排序

`CFBundleVersion` 不再使用 workflow run number。版本映射为 `(major × 100 + minor + 1).patch.slot`：preview 的 slot 是 1…98，未来稳定版保留 99。支持 major 0…98、minor/patch 0…99；超出范围明确拒绝，不取模、不截断。

- `0.1.0-preview.9` → `2.0.9`
- `0.1.0-preview.10` → `2.0.10`
- 未来 `0.1.0` → `2.0.99`
- `0.1.1-preview.1` → `2.1.1`

这满足三个数字组件的格式，并避免 Sparkle 忽略第一个连字符之后的版本信息。完整 preview 版本仍记录在 `MoeKitPreviewVersion` 与 appcast short version；workflow run/attempt 单独记录 provenance。此 signed-preview workflow 仍只发布 prerelease，尚不发布稳定版。

## 签名 feed 与不可变资产

固定 feed 是 `https://raw.githubusercontent.com/cosZone/MoeKit/updates/appcast.xml`。App 必须同时启用 `SURequireSignedFeed`、`SUVerifyUpdateBeforeExtraction`，将 signed-feed failure expiration 设为 0；不会因长期签名失败而退回未验证 feed。默认不静默自动安装，不上传系统画像，不在 release notes 执行 JavaScript。

签名 utility 只从固定官方 ZIP 提取 `bin/sign_update`，再次验证其 SHA-256 `43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b`。下载及验证发生在任何私有签名 secrets 注入之前。公开公钥 Secret 可用于无私钥的构建校验，但只在与受审公钥相等后使用。私钥只通过捕获输出的 stdin 传入 `--ed-key-file -`，不放命令行、不输出原始错误；签名命令的环境不继承发布/Apple secrets。独立 OpenSSL Ed25519 验证只需受审公钥，避免把同一私钥工具的自验当作公钥匹配证明。

ZIP 的最终字节与 appcast 原始 UTF-8 字节分别签名。Feed 内只有精确版本、语义 build、来源及本仓库该版本的固定 ZIP 下载地址，版本说明内嵌；preview 明确标注 `sparkle:channel=preview`，用户关闭预览版后不会把它当成默认频道更新。未来稳定版才不标注频道。不使用外部未签名 notes、delta 或任意下载 URL。签名验证发生在 XML 解析前，并核对唯一终止签名注释、长度、版本、频道、来源、URL 与 archive 字节。任何重新排版也会使签名失效。

每个新 Release 包含 DMG、ZIP、`BUILD_INFO.json`、`SHA256SUMS.txt` 和已签名 `appcast.xml` 五个资产。原有版本不改写、不补传、不删除。先创建 draft，逐个验证 GitHub 返回的长度和 SHA-256，发布为 prerelease 后才更新 feed。

`updates` 分支仅承载 `appcast.xml`，保存历史。存在时必须先验证旧 feed 同一公钥签名与版本，再创建以其当前 HEAD 为 parent 的 commit，非 force 更新引用；并发修改或非递增版本拒绝。首次使用创建独立分支。Feed 更新失败时已发布资产保持原样，不能声称自动更新已交付；可选择新 preview 版本继续，既有 tag、draft 和资产仍不覆盖。

当前 active feed 只包含最新的一项 preview，Git 历史不等于同时保留多个频道的可用更新。未来启用稳定版发布前，需要另行实现并验证多条目或独立频道 feed，使发布新 preview 后仍保留可供稳定版用户选择的稳定更新；本次不宣称该行为已实现。

## 验证边界

便携测试使用非生产测试密钥与合成资产验证 tamper、错误公钥、错误 URL、重放及并发更新拒绝；原生 release helper 测试对合成 universal bundle 逐层 ad-hoc 签名，验证框架链接、ZIP、DMG 与每个 code object。实际签名安装/重启由独立的隔离 Sparkle fixture 验证，不能用 parser 或 archive pass 代替。

[preview.10](../website/content/changelog/0.1.0-preview.10.md) 已取得生产签名、固定公钥与 ZIP／feed 签名一致性、五份公开资产和首个 updates 分支的验证证据，是首个包含更新器的发布包；preview.9 及更早版本仍需先手动安装它。双架构合成 fixture 的安装／重启已验证，但真实用户安装的生产签名 App 后续更新、Gatekeeper 和隐私授权迁移仍需各自验收；源码、CI 和签名成功不能代替这些结果。

依据：[Sparkle setup](https://sparkle-project.org/documentation/)、[发布与签名 feed](https://sparkle-project.org/documentation/publishing/)、[逐层重签说明](https://sparkle-project.org/documentation/sandboxing/)、[固定版签名实现](https://github.com/sparkle-project/Sparkle/blob/eef1a539a373c1f1a320624b1130fc5de7b2e100/common_cli/Signing.swift)、[OpenSSL Ed25519 verification](https://docs.openssl.org/3.0/man1/openssl-pkeyutl/#ed25519-and-ed448-algorithms)。
