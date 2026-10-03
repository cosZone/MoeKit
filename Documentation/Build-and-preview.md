# 构建与预览产物

## 工具链

- 部署目标：macOS 15；Swift 6 严格并发检查
- CI runner：标准 GitHub-hosted `macos-15`，显式使用 Xcode 16.4
- Tuist：`.mise.toml` 固定 4.148.3；Mise 固定 2026.3.10
- 第三方 Actions 均固定完整 commit SHA，注释标明版本；使用 Tuist 官方文档推荐的 Mise 安装路径，没有远程脚本管道安装
- `Package.swift` 是空 SPM 依赖清单，应用和测试目标在 `Project.swift` 中定义

在 macOS 安装所列工具后：

```sh
python3 Scripts/verify-source.py
mise install
mise exec -- tuist generate --no-open
open MoeKit.xcworkspace
```

初始 Linux 编辑环境未执行 Tuist 生成、Swift 编译或原生测试。Python 检查只验证目录、JSON、图片引用和本里程碑的源码约束，不能验证 Swift 语义或运行效果。

## CI 与手动预览

`ci.yml` 在 pull request、main push 或手动触发时执行源码检查、生成 workspace、`build-for-testing`、`test-without-building`。测试结果保留为 Actions artifact 14 天。PR 构建可能针对 GitHub 的合并测试提交，以运行记录 SHA 为准。

`preview-build.yml` **仅允许 workflow_dispatch**：

1. 检出此次 dispatch 的精确 `github.sha`，核对 HEAD；不跟随移动中的分支重新取源码
2. 同一次构建生成 universal Debug app 与测试，随后运行已构建测试；只在 runner 自身架构运行测试
3. 验证现有 ad-hoc 签名及 arm64 / x86_64 slice；不重新编译、不在测试后改写 `.app`
4. 使用 `ditto` 打包，附 `SOURCE_COMMIT.txt`、`SHA256SUMS.txt`、`BUILD_INFO.txt`
5. 上传下载用 artifact，保留 14 天；任何构建、测试或签名验证失败都不会产生预览包

在 Actions 中选择 Preview app artifact → Run workflow，选择要验证的分支或 tag。完成后从该次运行的 Artifacts 下载 `MoeKit-preview-<完整SHA>`。解开 Actions 外层压缩包后，内层 ZIP 包含 `MoeKit.app`。校验可在同一目录执行：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

这个预览是 Debug 构建，不代表生产优化构建或双架构实机验收。它仅有 ad-hoc 签名，**没有 Developer ID 签名，没有 Apple 公证**；Gatekeeper 可能阻止启动。请核对来源和校验和，遵循 [Apple 的安全说明](https://support.apple.com/en-us/102445)。不提供关闭 Gatekeeper、删除 quarantine 或绕过安全检查的命令。

## 签名与发布边界

CI 仅有 `contents: read`，不创建 tag、不创建 Release、不合并分支。它不接触证书、私钥、Developer ID 身份、Apple 账户或公证凭据，也不添加 GitHub 签名 secrets。

后续 Developer ID 签名与发布工作流尚待单独配置及审核；本预览工作流不依赖任何签名 secret。签名会改变应用和 ZIP 字节，必须重新验证签名、重新计算校验和、记录原始源码 SHA；不能复用原 ad-hoc ZIP 的校验和。签名、公证和 GitHub Release 是不同步骤，均不得把前一步的成功当成后一步已完成。

## 官方参考

- [Tuist 安装](https://tuist.dev/en/docs/guides/install-tuist) 与 [GitHub Actions 集成](https://tuist.dev/en/docs/guides/integrations/continuous-integration)
- [Tuist 4.148.3](https://github.com/tuist/tuist/releases/tag/4.148.3) 与 [Mise Action v4.3.0](https://github.com/jdx/mise-action/releases/tag/v4.3.0)
- [GitHub macOS 15 runner 工具清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)

Runner 镜像会更新。若 Xcode 16.4 被移除，应审核并显式更新工具链，不能静默切换后宣称是原环境的可复现结果。
