---
title: 项目管理
description: 从你选择的文件夹开始，整理已经存在的 Git 项目。
---

## 发现与导入

1. 在 Projects 中选择要检查的根目录
2. 等待只读发现完成，查看结果及不完整提示
3. 勾选需要加入的项目，再确认导入
4. 使用搜索、排序、置顶和 inspector 整理列表；需要时在 Finder 定位

发现器通过 Foundation 读取目录和少量 Git 元数据，不调用 Git、shell、项目脚本或 hooks，也不修改项目内容。

## 扫描有明确范围

默认最多扫描 4 层、2,000 个目录、100,000 个枚举项；每次读取 Git 元数据最多 16 KiB。符号链接、隐藏目录和常见依赖或构建目录会被跳过。找到 Git 根后，不继续深入该仓库。

达到限制、权限不足或元数据读取失败时，结果会保留不完整状态。没发现项目不一定表示目录里没有仓库。

## 分支与 worktree

`.git` 目录或文件只用于识别布局及读取 HEAD。显示的分支信息不是实时 Git 状态，也不代表工作区干净。

Git file 可以出现在 worktree 或 submodule 布局中，不能单靠它推断上游关系。外部元数据路径会做范围检查；目录可能同时变化，因此这些检查不是完全消除文件系统竞态的安全边界。

## 什么会保存

应用只在自己的 `~/Library/Application Support/MoeKit/projects.json` 中保存项目名称、路径、置顶状态和最近 Finder 定位时间。

当前预览没有 App Sandbox entitlement。目录选择与范围检查是应用行为约束，不能当作操作系统强制的沙箱隔离。

## 关联进程

项目详情中的 Related processes 打开一个筛选视图，不会隐式扫描。进入后由你主动刷新；关联依据仅是进程工作目录位于项目路径之内，不能证明进程由 MoeKit 启动或归项目独占。[了解进程关联](/docs/processes)

## Git 整理（preview.9）

Projects → Git cleanup… 可分别检查并确认一个干净 linked worktree 的退役，或一个已合并、未检出的 loose 本地分支移除。要选择同时覆盖主仓库和 worktree 的父目录，指定保留的本地 base，并确认停止使用目标；不会自动 fetch。

操作把 worktree／登记或 ref 移入主仓库 `.git/moekit-recovery/<操作 UUID>`，保留数据；退役不删除分支，删除分支必须另行确认。会话内可另行确认原路径恢复，不覆盖。移动不释放磁盘空间，没有 force 或永久删除入口。重启后保留恢复目录与 JSON 凭据，不会自动恢复或清空。

普通 SHA-1／index v2、同卷本地目录是首个支持范围。退役拒绝脏文件、untracked／ignored、独有提交、锁定或主 worktree 及重叠项目；分支移除拒绝任何 worktree 正在检出的分支和 packed 删除目标。链接、跨范围、受保护或未知配置同样不可操作。Git 只读取配置隔离的临时对象副本，不运行目标仓库的 hooks、filters 或脚本；不自动下载安装或捆绑 Apple Git。

这套操作已随 [preview.9](/changelog/0.1.0-preview.9) 交付，preview.8 不包含。恢复另行确认，不覆盖原路径；两个移动不是事务，部分结果保留数据并停止，不自动重试。详细预算、工具来源和恢复限制见 [设计记录](https://github.com/cosZone/MoeKit/blob/c5de70153e2eb6f9d1c547c17cf3926565514e50/Documentation/Git-cleanup-design.md)。
