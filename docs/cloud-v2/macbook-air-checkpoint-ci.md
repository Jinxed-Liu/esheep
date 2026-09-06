# 当前 MacBook Air 检查点 CI

用户于 2026-09-06 指定使用当前 MacBook Air。该配置用于候选构建，不代表允许跳过统一发布门禁。

## 已配置

- 仓库：`Jinxed-Liu/esheep`，当前为公开仓库。
- 环境：`esheep-cloud-checkpoints`，仅 `main` 分支，审核者为仓库所有者。
- 外部贡献者 Actions 运行均要求审核。
- Runner：`esheep-macbook-air-checkpoints`，标签 `self-hosted, macOS, ARM64, esheep-checkpoints`，一次性执行。
- 当前安装：`~/Library/Application Support/eSheepCheckpointCI/runner-2.337.0`，官方 ARM64 安装包 SHA-256 为 `5a2cd92908a93d7276a194e1de6008099f3e7946f3f8e14aa7a1a7b4a31fdec2`。
- 已配置生产项目、牧场、模拟器、批准历史证据路径、ESMotion 仓库与固定 commit 六项环境变量。

Runner 当前离线，未安装登录启动或常驻服务，未向 GitHub 复制源读取凭据或发布凭据。环境审核不是主机隔离；这台机器同时保存开发凭据和真实数据，不接收未审核代码。

## 首次受控运行条件

1. 完整实现经审查后，将确定的工作流与匹配源码提交到允许的主分支；不能让工作流使用另一份旧客户端代码。
2. 校验 ESMotion 固定提交、批准历史文件哈希、Xcode 与指定模拟器可用性。
3. 为源读取准备经确认的最小权限凭据；候选任务不配置发布凭据。
4. 核对待执行任务的仓库、事件类型、分支、提交与环境审核结果，再启动一次性 runner。不要安装 `svc.sh` 常驻服务。
5. 执行后核对本机候选、独立 SQLite 对账、批准历史对账和源封存证明；一次性 runner 完成任务后注销。

手动触发和每日检查已写入工作流，但当前尚未在 GitHub 实际执行。离线的一次性 runner 不能被算作已经提供无人值守每日构建；该运行管理仍需在首次受控任务中验证。

## 证据保留

公开 GitHub 任务摘要只记录各项通过/失败，不上传完整业务对账、分片或云源。完整文件保留在本机受保护输出目录中，按候选身份和运行号管理。

本轮配置证据：`backups/cloud-v2-integrated-20260906-153230/verification/macbook-air-ci-configuration.json`。

## 检查点功能回退

迁移 `20260906120000_esheep_checkpoint_rollout_controls.sql` 提供 `esheep_cloud.checkpoint_rollout_controls`：

- `new_receives_enabled=false`：通过现有成员校验后，仅新接收获得空清单及 `new_checkpoint_receives_paused` 原因，从而走旧快照路径。明确指定检查点的恢复仍请求原版本，不丢掉已下载进度。
- `publication_enabled=false`：拒绝发布入口，包括重复激活请求；原有已验证检查点与事件账本保留。
- 恢复相应开关即可恢复该功能。开关按牧场和 generation 生效，普通客户端没有更新权限。
- 客户端本地清理仍由 `ESheepCloudDisableCheckpointCleanup` 禁用开关控制。

这些开关不撤销已接受的命令，也不关闭兼容写入函数。本轮仅在隔离后端验证，未修改生产开关。

## 候选与新检查点保留门禁

候选必须附独立 SQLite、批准历史和用途历史三份通过报告，并绑定清单与云源哈希。发布脚本逐份验证通过状态与边界，服务端保留三份报告摘要的组合哈希；缺失或错配报告的离线拒绝回归已通过。分片模型索引必须与解压内容一致，发布器拒绝缺失索引的早期试跑候选。

`tools/maintain_esheep_cloud_checkpoints.py` 默认只审计。受控执行保留最近两个已验证版本及固定调查版本；旧版本退役后等待 10 分钟，再认领、删除精确私有分片、回读不存在并确认完成。只处理新检查点 bucket，不接触旧快照和事件账本。该工具已在隔离后端通过实际 HTTP，尚未接入生产定时任务，也未执行生产清理。
