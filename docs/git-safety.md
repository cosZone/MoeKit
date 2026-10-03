> 历史专项规划：以下内容主要描述项目产物与清理安全等未来能力，不是当前已实现清单。MoeKit 的最新定位为个人 CLI 原生工具箱；当前实现和验证状态见 [README](../README.md)。

# Git 工作区与分支保护

状态：planned。本文是产品与实施蓝图，尚无可运行应用或已验证的执行能力。

## Git 退役规则

Git 原生命令是基础实现来源，具体选项须按用户安装的版本检查。应用会在 Git 的行为之上增加产品级保护。[Git worktree 文档](https://git-scm.com/docs/git-worktree)

- 主 checkout、bare 仓库根、已保护项、locked worktree 不进入普通退役流程
- staged、unstaged、冲突、untracked、未审查 ignored 内容均阻止普通移除
- detached HEAD、独有提交、浅克隆、partial clone、缺失对象、子模块、嵌套仓库与高级 index 状态需要单独处理；首版保守阻断
- merge/rebase/cherry-pick/revert/bisect 等操作进行中，或有锁、活动变化、权限异常时停止
- 保留分支可以保留仍由该分支引用的已提交历史，但不会保存工作目录里的未提交/忽略文件
- 普通 `git worktree remove` 不能代替忽略文件检查，也不是 Finder Trash
- 不因 remote branch 消失、PR 已关闭、目录很旧或 Git status 没有普通改动就判定可丢弃
- 不自动解除锁，不将失败命令升级为 force，不自动重试更宽范围

### 分支关系要说清依据

每个仓库明确选择比较基准，记录被检查的 base 和 branch tip OID。界面分别表达：祖先关系、upstream ahead/behind、补丁等价线索、PR 状态和远端信息新鲜度。

Squash/rebase 后没有普通祖先关系，不能直接解释成“工作未合入”；反过来，PR 曾经合并也不能证明后来新增的本地提交已保存。高级判断应显示证据和局限，不包装成通用证明。[Git merge-base](https://git-scm.com/docs/git-merge-base) · [Git rev-list](https://git-scm.com/docs/git-rev-list)

后续本地分支删除需独立审核。批量计划要检查整批操作完成后仍会保留的 refs，避免两个待删分支相互充当唯一保留依据。Git 的普通分支删除保护是附加门槛；失败后保留分支，不自动换成强制删除。[Git branch](https://git-scm.com/docs/git-branch)

### Prune 是独立维护操作

Git worktree prune 清理的是失效登记，不是现存工作目录。后续 UI 必须展示仓库范围的完整预览、明确的过期边界，并在执行前重新检查。不能伪装成只影响某一行；外接盘未挂载也不能当成目录已废弃。

返回 [README](../README.md) · [文档目录](README.md)
