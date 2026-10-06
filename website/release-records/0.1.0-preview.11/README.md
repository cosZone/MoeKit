# preview.11 发布验证记录

此目录保存发布时的审计材料。面向用户的简短说明位于 [更新记录](../../content/changelog/0.1.0-preview.11.md)。

- `signed-notes.md`：源码 `6b23cb267bdb140fa8f2834638658dbc60dadf90` 中的完整原始文件，逐字节保留；原文件的 unreleased 元数据反映发布前快照
- `original-release-body.md`：发布工作流最初生成的 GitHub Release 正文，逐字节保留
- `provenance.json`：原始文件哈希、发布源码/run、五份公开资产摘要及 feed 历史；这些哈希不用于校验后来简化的展示说明

GitHub／网站展示说明可以编辑。已上传的 DMG、ZIP、构建信息、校验和和签名 appcast 未被改写；preview.11 的更新弹窗仍使用原始已签名说明，后续版本从简短说明生成新的 feed。

## 已核验

[发布运行](https://github.com/cosZone/MoeKit/actions/runs/37491185118)的 build-and-test、sign、publish 均成功，run16／attempt1，内部 build2.0.11。发布 Swift Testing 报告621项，其中41项显式 opt-in 检查跳过；另有20项 XCTest、129项发布辅助测试、20项 appcast 测试通过。跳过项不计为本次实际执行通过。

同源码 [Native CI](https://github.com/cosZone/MoeKit/actions/runs/37489235661) 五个 job、[Docs CI](https://github.com/cosZone/MoeKit/actions/runs/37489235238) 和 [Sparkle fixture](https://github.com/cosZone/MoeKit/actions/runs/37489235271) 均通过。Native Debug有620项 Swift测试、20项 XCTest及17项中文定向渲染；owned socket日志确认0／106／0字节边界。两架构共20个合成更新场景逐项核验安装、重启、偏好保留、篡改／版本／渠道／取消拒绝。Docker在相同受审代码树的独立自有daemon中验证精确删除、受保护邻居与卷保留，以及构建缓存6→0；这不代表真实用户daemon验收。

五份公开资产已下载并核对 GitHub digest、SHA256SUMS、BUILD_INFO、Info.plist和完整ZIP App内容。App内容摘要为 `8c45b17d403359476ed603fac356b90a48820a168f1d3db226d1c0b7f6cfebc8`。固定公钥下的生产 ZIP／feed Ed25519签名通过，修改字节的对照被拒绝；原始GitHub正文与发布代码生成结果一致。

macOS签名job核验八份代码的双架构、Apple anchor／预期证书与团队、Hardened Runtime和空entitlements；DMG完整性、只读挂载及两包内App字节一致性通过。另有补充Linux检查验证16份CMS数学签名、2,383个代码页及特殊槽绑定，并拒绝页篡改；这项补充不代替Apple证书链信任、完整资源规则或嵌套代码语义。

updates提交保留父提交，且只含appcast.xml；公开固定feed、Release资产与Git blob字节相同。发布包固定为上述源码，不包含随后合入的Mole新手准备或AI worktree流程。

## 未验证与分发限制

Apple Development开发签名，未公证。完整用户窗口、键盘、VoiceOver、Docker Desktop实机、真实隐私权限，以及用户已安装的生产App完成一次更新仍需验收。合成fixture使用测试密钥和ad-hoc应用，不能替代这些项目。没有清理真实用户数据，也没有读取或修改生产私钥。
