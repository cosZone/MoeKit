> 历史专项规划：以下内容主要描述项目产物与清理安全等未来能力，不是当前已实现清单。MoeKit 的最新定位为个人 CLI 原生工具箱；当前实现和验证状态见 [README](../README.md)。

# 灵感、复用与许可边界

状态：planned。本文是产品与实施蓝图，尚无可运行应用或已验证的执行能力。

## 灵感与复用地图

以下映射依据 2026-10-03 的公开资料研究；产品与许可可能更新。它们是要学习和评估的方向，不是依赖清单、功能验证报告或市场独占性声明。

| 参考来源 | 具体借鉴意图 | 计划采用方式与边界 |
| --- | --- | --- |
| [Mole CLI](https://github.com/tw93/Mole) | 以项目组织开发产物、成熟的生态规则与执行能力 | 优先评估调用用户已安装 CLI；先验证版本、限域、预览和删除语义；不复制其脚本或宣称普遍可撤销 |
| [Mole 原生 app](https://mole.fit/docs) | 清理与恢复成本说明，查看 app/CLI 的能力差异 | 仅研究公开交互和文档；不复制其专有 SwiftUI 实现或付费资源，preview 能力不写成 stable |
| [ClearDisk](https://github.com/bysiber/cleardisk) | 清楚解释开发缓存、风险与 Trash/实际回收的区别 | 独立设计简洁 UI 和说明；若未来借源码须逐项审核 MIT 及依赖通知，当前无源码移植 |
| [Worktrunk](https://worktrunk.dev/remove/) | 丰富的集成判断、锁保护、计划与清理细节 | 作为安全行为对照和后续可选适配器；不把高级算法结论或 hooks 当作应用默认授权 |
| [gfold](https://github.com/nickgerace/gfold) | 用户选定范围的跨仓库发现和只读库存 | 借鉴发现流程，后续可选 subprocess 接入；完整 worktree 关系仍经 Git 验证 |
| [teebe](https://github.com/klein-t/teebe) | 原生跨项目 worktree 列表、检查器与实时刷新 | 独立实现交互概念；GPL/商业许可需单独评估，不默认复制 SwiftUI/Core 源码 |
| [Farol](https://tryfarol.app/blog/remove-git-worktree-safely) | 轻量导航、删除前检查、移除 checkout 与删分支分离 | 参考公开工作流；独立 UI，不复制私有实现或品牌资产 |
| [DevCleaner 项目休眠](https://devcleaner.app/docs/hibernation) | 归档前验证、重建成本、项目恢复 | 作为后续归档产品需求参考；独立设计归档格式和验证机制 |
| [DevCleaner 证据记录](https://devcleaner.app/docs/evidence-and-records) | 路径、命令、失败和重建提示可追溯 | 借鉴可解释历史；明确 manifest 不等于 backup |
| [Pearcleaner](https://github.com/alienator88/Pearcleaner) | 有边界的 Trash 历史和恢复交互 | 研究体验；注意 Apache 2.0 + Commons Clause 条件与维护状态，不当作可任意复制源码 |
| [Git 官方文档](https://git-scm.com/docs/git-worktree) | 仓库身份、状态、ref 与 worktree 生命周期的基础语义 | 调用本机 Git 的受约束接口，并用应用保护规则补足产品需求 |

### 许可边界

需要区分三种行为：

1. **独立设计：** 从公开功能与问题中学习，使用自己的模型、文案、界面与实现；不复制第三方代码、品牌、图标或截图作为产品资源
2. **subprocess 集成：** 调用用户已经安装并主动启用的工具，仍需审查具体交互、分发方式、许可证与条款；不能声称只要分进程就一定没有义务
3. **源码移植、链接或捆绑分发：** 逐文件确认许可、版权通知、修改和分发要求及依赖。GPL、Commons Clause、商业双许可和专有 app 不能一概按宽松许可证处理

当前规划未移植第三方代码，也不决定本项目的最终许可证。Mole CLI 的 GPL 与其原生 app 的商业条款需要分别对待；teebe、Pearcleaner 等同样按实际版本和文件核实。拟定分发方案后做专项许可审查，必要时寻求法律意见。这里不提供法律保证。

返回 [README](../README.md) · [文档目录](README.md)
