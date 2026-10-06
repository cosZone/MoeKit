# MoeKit

把项目、磁盘整理和本地工具放进一个原生 macOS 工作台。

**[下载 preview.12 DMG](https://github.com/cosZone/MoeKit/releases/download/v0.1.0-preview.12/MoeKit-v0.1.0-preview.12-macOS.dmg)** · [ZIP](https://github.com/cosZone/MoeKit/releases/download/v0.1.0-preview.12/MoeKit-v0.1.0-preview.12-macOS.zip) · [更新记录](website/content/changelog/0.1.0-preview.12.md)

macOS 15+ · Apple Silicon / Intel · SwiftUI / AppKit

![MoeKit 项目工作台，使用示例数据](docs/assets/moekit-projects-demo.png)

## 能做什么

- **项目**：发现 Git 项目与 worktree；复查后合入、按需推送，单独确认退役
- **磁盘**：用 Mole 分析目录，清理可重建缓存，管理个人废纸篓
- **Docker**：清理选中的闲置镜像、停止容器和单独确认的未使用构建缓存
- **进程**：查看进程与端口，复查后结束支持的精确选择
- **菜单栏与更新**：快捷打开工作区、查看任务状态，通过 Sparkle 检查与安装新版

## 开始使用

1. 下载 DMG，将 MoeKit 拖到 Applications 后打开
2. 在 Projects 选择项目目录；想先看看，可在 Settings → Preview 开启 Demo
3. 打开 Mole 分析窗口，自动检查兼容安装；未找到时按 [准备指南](https://github.com/cosZone/MoeKit/blob/fa630c57dd87862597874d5ba459453beac95e60/Documentation/Mole-beginner-setup.md) 操作，再重新检测

当前仍是开发预览：Apple Development 签名、未公证，macOS 可能阻止打开。永久删除不可恢复；MoeKit 不会自动清理你的数据。preview.9 及更早版本需先手动安装一次。

## 文档与反馈

[使用文档](website/content/docs/index.md) · [功能范围](website/content/docs/status.md) · [反馈问题](https://github.com/cosZone/MoeKit/issues) · [Roadmap](https://github.com/cosZone/MoeKit/issues/40)

开发者：[构建说明](Documentation/Build-and-preview.md) · [架构](Documentation/Architecture.md) · [发布验证记录](website/release-records/0.1.0-preview.12/README.md)

项目许可证尚未确定。Mole 是独立上游项目，其分析器不随 MoeKit 打包。
