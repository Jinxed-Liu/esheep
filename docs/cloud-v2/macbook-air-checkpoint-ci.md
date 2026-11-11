# Apple silicon Mac 检查点候选 CI

本文路径保留以兼容旧链接。2026-09-06 的 MacBook Air 配置属于历史记录，不证明当前机器已接管。2026-11-10 本地核查确认 M6 Mac、Xcode 27.2 和 Swift 6.4.2 可用；本地修复尚未部署，未注册/启动 Runner、审批 GitHub 任务或读取生产源。

## 执行边界

- 仓库 `Jinxed-Liu/esheep` 是公开仓库。仅经审核的 main 代码使用 `esheep-cloud-checkpoints` 受保护环境；不得绕过环境审批。
- 工作流要求标签 `self-hosted, macOS, ARM64, esheep-checkpoints`。使用一次性 Runner，不安装 `svc.sh` 常驻服务。新增机器建议使用独立名称 `esheep-macbook-pro-m6-checkpoints`，不要覆盖旧设备注册。
- 环境审批不提供主机隔离。执行机器可能保存开发凭据和真实数据，不接收未审核代码。
- 只构建候选、核对三份证明；不发布、不修改牧场记录、不配置发布凭据。
- 原有每日 schedule 和人工审批保留；一次性 Runner 不代表无人值守日更。旧待批运行使用旧提交，不能通过批准旧任务来验收新修复。

## 受保护配置

GitHub 会显示普通 env 的值。运行入口改为读取两个 **environment secrets**，避免把牧场标识、历史路径等直接写进公开步骤头：

1. `ESHEEP_CHECKPOINT_SOURCE_TOKEN`：限定目标项目和数据库读取权限的显式凭据。缺失时拒绝执行，不回退到主机上已有登录。不能以只读 SQL 为由使用具有不必要写入权限的凭据。
2. `ESHEEP_CHECKPOINT_WORKER_CONFIG`：以下六个字段的 JSON 对象。值须经审核确定；此示例是占位模板，不可直接用于运行。

```json
{
  "project": "<20-character project ref>",
  "farm": "<approved farm UUID>",
  "destination": "platform=iOS Simulator,id=<installed simulator UUID>",
  "approved_source": "<absolute path to the complete sealed approval directory>",
  "approved_sha256": "<SHA-256 of the reviewed semantic-reconciliation.json>",
  "evidence_root": "/Users/jinx/Library/Application Support/eSheepCheckpointCI/evidence"
}
```

必须固定批准证明本身的哈希，不能只在运行时对任意找到的文件计算哈希后自动信任。原来的六项普通环境变量不再被此工作流读取；ESMotion 已位于仓库内 `Packages/ESMotion`，不再检出另一仓库。新增 secrets 与生产读取授权仍需单独批准，本地修改不会创建它们。

## 本地依赖和前置检查

- 完整 Xcode，首次启动组件已就绪，Swift 至少 6.2，arm64 架构。
- Python 3.9+ 标准库、Git；指定 UUID 的 iOS Simulator 已安装且可用。检查不启动模拟器。
- Supabase CLI **3.0.0**，由 `tools/checkpoint_source_cli.py` 固定并核对版本及查询参数。2026-11-10 已核验官方 macOS ARM64 归档 SHA-256 `3b0bfc4602cd7d55ffc78a6b72443d3b8e5fdd856b777e75977978dceb3e44cc`，在任务临时目录运行了版本和帮助；没有安装到全局 PATH，也没有验证生产查询。
- 查询显式指定 `--remote=<project>`、`--read-only`、JSON 输出，关闭交互 stdin；兼容普通数组与 agent 模式 `rows` 对象。不得加 `--yes` 代替只读参数。
- 私有证据根目录须预先存在、由执行用户拥有、权限为 0700，且不在仓库、`RUNNER_TEMP`、`GITHUB_WORKSPACE` 或 `RUNNER_WORKSPACE` 内。入口不自动创建/重定向证据根。
- 五项历史文件须齐全：`semantic-reconciliation.json`、`post-repair-field-audit.json`、`commands.json`、`expected-sheep.json`、`expected-business.json`。检查固定批准证明哈希、四项输入哈希、通过状态、牧场及 generation 一致性、命令身份；缺失、重名哈希或不一致均在生产读取前失败。

配置通过后，把已验证的同一批文件字节复制到本次私有运行目录，构建只使用该副本，防止检查后的原目录变更影响输入。源抓取后的原有核验继续验证 generation 和批准命令是否位于所捕获的不可变事件前缀中；离线检查不能替代这一步。

```bash
# 在显式提供上述配置、凭据和运行标识的进程环境中执行。
# 只读本机工具和批准文件；不查询数据库，不运行候选。
python3 tools/run_esheep_checkpoint_candidate.py --preflight-only

# 纯离线回归；只使用合成数据，截获所有可能执行候选的子进程。
python3 -m unittest discover -s tools -p 'test_checkpoint_candidate_worker.py' -v
```

## 首次受控执行与证据保留

1. 找回完整批准证据、核实封存哈希与历史边界；不能拿其他批次的同名文件或手机缓存替代。
2. 在独立审查中固定工作流与源码提交、Runner 安装包、环境配置、凭据权限、数据范围及证据保留路径。
3. 获得对应操作批准后，才配置/注册 Runner、审批目标任务、启动一次性 Runner。不要直接批准仍使用旧工作流的待批任务。
4. 输出位于 `evidence_root/esheep-checkpoint-<run-id>-<attempt>/`：`worker.log` 为完整入口日志，`approved-source/` 为批准输入封存副本，`build/` 保存云源、构建日志及候选，`outcome.json` 为状态。文件默认 0600；既有同名运行目录拒绝覆盖。
5. 公开日志只输出固定阶段名、状态和退出码；摘要仅显示通过/失败/未生成/格式错误。完整 SQL、CLI 返回值、异常与业务对账不上传 artifacts，也不打印到公开日志。
6. 任务结束后核对源封存证明和独立 SQLite、批准历史、用途历史三份报告，再单独考虑发布。一次性 Runner 注销不会清理此持久证据目录；清理需另行审核，工作流不自动删除证据。

历史配置曾引用 `backups/cloud-v2-integrated-20260906-153230/verification/macbook-air-ci-configuration.json`。本机尚未找到该文件，不能据此恢复旧配置或认定迁移完整。

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
