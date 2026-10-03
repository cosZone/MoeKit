# 恢复材料与操作历史

状态：planned。本文是产品与实施蓝图，尚无可运行应用或已验证的执行能力。

## 恢复与历史

恢复入口按实际机制命名，不能统一宣传为“任何操作都能 Undo”。

| 机制 | 能提供什么 | 不能承诺什么 |
| --- | --- | --- |
| 操作日志/删除清单 | 说明发生了什么、对应路径与结果 | 不能保存已删除文件或 Git 对象 |
| Finder Trash | 对确实移入 Trash 且仍存在的普通文件提供恢复可能 | 不是空间已经释放；不能自动恢复任意 worktree 登记 |
| 保留 branch/ref | 保留仍可达的提交，满足条件时可重新创建 checkout | 不包含未提交、untracked、ignored 文件，也不抵御仓库整体丢失 |
| 已验证 Git bundle | 保存明确范围内的已提交历史 | 不自动包含工作目录、index、hooks、配置或所有 stash 状态 |
| 项目归档 | 后续为明确文件范围提供验证后的恢复材料 | 不保证所有外部依赖、系统状态和下载结果可重现 |

记录原路径、身份、ref/OID、工具版本、时间、每项结果及恢复材料位置。恢复前检查归档完整性、目标路径冲突、仓库是否还在、ref 是否变化、布局和可用空间；不覆盖后来创建的新工作区。

保存在同一磁盘上的归档仍占空间。界面分别展示“移入 Trash”“已移除的估算大小”“备份占用”，不将逻辑文件大小或 APFS clone 的大小当作保证释放的物理空间。[Git bundle](https://git-scm.com/docs/git-bundle) · [Apple 文件分配空间](https://developer.apple.com/documentation/foundation/urlresourcevalues/totalfileallocatedsize)

返回 [README](../README.md) · [文档目录](README.md)
