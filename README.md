# eSheepNext

新一代 eSheep+ 的独立 iPhone/iPad 工程。最低系统版本为 iOS/iPadOS 26.1，采用 Swift 6、SwiftUI、SwiftData、Apple 原生 Liquid Glass 与蓝色品牌基线。旧版 `/Users/asiha/Desktop/eSheepPlus` 未被修改。

> **3.1 当前架构说明：** 当前权威文档是
> [`docs/eSheepNext-3.1-storage-implementation.md`](docs/eSheepNext-3.1-storage-implementation.md)。
> 3.1 由每个牧场的 `FarmStorageProfile` 选择 local-only、Supabase 或 iCloud
> 权威；`FarmCommandService` 仍是唯一业务写入入口，Outbox 在创建时固定
> provider 与 authority generation。本文后面明确标为“3.0 历史记录”的
> CloudBase/CloudKit 描述只保留迁移背景，不是 3.1 实施依据。

## 当前本地产品闭环

- 登录页同时提供邮箱验证码注册、账号密码登录和 Sign in with Apple；3.1
  Release/Staging 账号由 Supabase Auth 恢复，旧 iCloud 协作路径仍可按配置使用
  CloudBase 身份会话。退出只清除当前账号会话，保留隔离的本机牧场缓存与未同步记录。
- 已保存的本地工作区不绕过真实会话门禁；账号恢复、当前牧场成员权限和
  `FarmStorageProfile` 共同决定可见数据及远端路由，离线可用不等于可以更换云端权威。
- 多牧场本地隔离：每条业务实体、操作审计和 Outbox 都强制携带 `farmID`。
- SwiftData 已冻结为正式 `1.0.0` 版本化 Schema，并通过显式 `SchemaMigrationPlan` 打开持久化容器；启动失败不再崩溃，而是进入可重试、可导出诊断、可隔离原库的恢复入口。
- 统一命令管道：角色能力校验、业务验证、SwiftData 保存、`DomainOperation` 审计和 Outbox 入队。
- 首页可直接进入建羊、称重、转群和离场；统一导航也支持搜索结果和 App Intent 直接打开羊只详情。
- 圈舍支持改名、备注、停用和重新启用；羊只支持修改耳号、品种、性别、出生日期和备注。耳号在牧场内永久唯一，圈舍仍有在群羊或受保护历史引用时拒绝破坏性操作。
- 称重、转群和离场支持详情、受控修正、撤销与恢复；修正会保留原事实的墓碑和审计，并从受影响时间重建羊只当前状态。
- 健康与繁殖统一进入 Care 命令链：批量健康、库存消耗、配种、孕检、流产、产羔、羔羊建档和断奶均保留可追溯关系，产羔修正/撤销不会删除羔羊或覆盖其后续记录。
- 羊只档案提供父母、两代祖先、同父/同母羊、直接后代、关系来源和不可变系谱审计；父本和供体写入要求历史事实编辑权限与修改原因，并阻断跨牧场、自身关系、性别错误、日期倒置和祖先循环。
- 冻精库存支持供体档案、批次关联和历史快照。父本候选按产羔日向前推牧场妊娠天数（默认 150 天），只检查当时同舍、在场且已明确标记的种公羊；普通公羊不参与，Core ML 仅在内置模型可用时排序，任何候选都不会自动确权。
- 羊群支持耳号/品种搜索、性别/状态/圈舍筛选、排序、分段加载和经命令管道执行的批量转群；单羊可导出包含基础资料与时间线的真实 XLSX。
- 原料库、配方、投喂多原料明细、投喂历史，以及按历史圈舍和真实羊天计算的自由采食分析。
- 只读的确定性本地牧场助手；它不编造数据，也不能直接写入。
- 原生五个 Tab、iPhone/iPad 适配、farm-scoped App Intents 与 Spotlight 索引、通知路由、后台补偿同步、可选牧场 Widget、App Icon、Privacy Manifest、Entitlement 基线和 Emoji 静态扫描。
- provider-routed 同步层：Supabase 与 CloudKit transport 都受
  `FarmStorageProfile`、固定 provider 的 Outbox 和 authority generation 约束；
  CloudKit 继续承载 iCloud 模式与旧数据迁移，Supabase 承载 3.1 配置选择它的牧场。
- **3.0 历史记录：** CloudBase 曾是唯一生产身份与协作服务、养殖业务数据只在
  CloudKit；此说法不再描述 3.1。CloudBase 网关和遗留 Worker 在调用方审计完成前
  仍保留测试与兼容路径，但不决定 3.1 业务数据 provider。
- **3.0 历史记录：** 3.0.0 免费版本及 StoreKit 开关说明仅用于追溯旧发布边界。
- 云端协作中心：正式迁移牧场云端状态、系统共享、邀请码、成员与证书、同步、冲突、安全事件和账户删除状态。
- Zone-wide `CKShare(recordZoneID:)`、成员安全 generation 快照、签名 Tombstone、冲突解决操作、压缩照片 `CKAsset`、场主私有加密照片副本与三份 checkpoint 保留策略。
- 每牧场 iCloud 钥匙串恢复密钥、`.esheep-recovery` 恢复包、恢复码包装、恢复点校验与约束检查后的签名恢复操作。
- 设置中心提供 XLSX、CSV、JSON 导入预览、重复与错误报告、稳定幂等键和命令化提交；导出会生成真实 OOXML `.xlsx`，不会把 CSV 改名伪装成工作簿。
- 设置中心另提供版本化 `FarmBackupEnvelopeV1` 完整本地备份。恢复先在独立临时 SwiftData 容器中校验 checksum、引用、耳号和历史状态，只允许写入空牧场，重复恢复保持幂等；XLSX/CSV 仍只作为人工查看和表格交换。
- 云缓存安全重建：全 Zone 分页拉取、独立磁盘 staging、签名与摘要校验、照片下载校验、历史重建、单事务业务缓存替换、未确认 Outbox 重放，以及失败后保留旧库和 staging 证据。
- 旧版牧场正式导入：阻断项清零后，将临时牧场、照片和版本化云端基线原子写入正式 SwiftData；同一来源包重复提交保持幂等，失败回滚数据库和资源目录。Development 在联网后自动续传至用户 iCloud，始终不修改 eSheep+ 或 Supabase。

## 当前阶段边界与外部状态

下列包含日期的真机与云端记录是 3.0 阶段历史证据；除非另有 3.1 验收报告，
不得把它们外推为当前 Supabase、稳定 Xcode Archive、TestFlight 或双账号验证结果。

这些步骤不能由仓库代码或无签名构建替代，尚未在本机伪造完成状态：

1. Debug/Development 已启用正式迁移牧场的 iCloud 双设备同步与成员邀请入口；同一账号两台真机的 private Zone 同步、断网续传、照片和重建已由用户在 2026-07-24 确认验收通过。两个不同账号的 shared Zone 邀请、撤权和连续七日验收仍未执行；Staging 与 Release 继续关闭。
2. 仓库内 CloudBase Gateway 当前代码版本为 0.4.6，已覆盖邮箱、Apple、刷新、退出、删除、限流、账户显示名称与头像同步、迁移牧场 `provisioning → active` 目录状态，以及牧场 UUID 大小写统一。历史 0.4.0 Development 部署和同账号头像跨设备一致性曾取得真机证据；这不证明当前 0.4.6 已部署，也不替代独立 Production 环境及双账号协作验收。
3. 登录成功后的业务写入只依赖本机 SwiftData；断网、CloudKit 关闭和重启不应阻断建羊、称重、转群、离场、修正、撤销、查询和备份恢复。
4. 新增的 `com.sheepfarm.next.dev.widget` Bundle ID 仍需要有效描述文件才能在连接设备上运行 XCTest；无签名 App/Test/Widget 编译不受此限制。

当前自动化基线以 `./tools/verify_local.sh` 的最新结果为准；同账号双真机验收与两个不同账号的共享协作验收必须分别记录，不能由编译、模拟响应或头像同步互相替代。

2026-07-20 的 128/128 XCTest、2026-07-24 的旧本地总门禁和 Gateway 20/20 只保留为历史证据。2026-08-27 静态审计约有 575 个 XCTest 方法；当前完整套件两次均在 CoreSimulatorService 环境中未进入 XCTest 子进程，因此不能记为代码失败，也不能记为全量通过。本轮新增图片/Identity transport 11/11、Root 生命周期 4/4、Web 8/8、遗留 Worker 16/16、CloudBase Gateway 33/33 均已分别通过；稳定 Xcode Archive、完整 XCTest、真机性能、数据库一次性环境和双账号协作仍是独立门禁。

云端准入按环境隔离：Development 只允许具有完整迁移提交、基线摘要和照片校验的正式迁移牧场，不再存在固定种子测试牧场路径；Staging/Production 云功能仍由构建开关关闭。迁移目录在完整上传前保持 provisioning，第二台设备和受邀成员只能发现 active 牧场。

3.1 当前边界见 `docs/eSheepNext-3.1-storage-implementation.md`；
`docs/云端协作安全设计.md`、`docs/CloudKit_Development配置清单.md` 和
`docs/Development七日验收记录.md` 均为旧 iCloud/3.0 路径资料。

## 本地验证

```bash
./tools/verify_local.sh static
./tools/verify_local.sh ios
./tools/verify_local.sh web backend
ALLOW_LOCAL_DB_RESET=1 ./tools/verify_local.sh db
./tools/verify_local.sh all
```

不传参数时默认执行 `all`。`db` 只使用本地 Supabase 容器，并在非 CI 环境要求显式确认后才允许 reset；任何入口都不会上传、发布、迁移生产数据或清理 `outputs/`。`ios` 继续拒绝把 Beta Xcode 当作正式发布门禁，只有显式设置 `ALLOW_BETA_XCODE=1` 时才可用于诊断。身份兼容路径和遗留 Worker 的实际调用边界见 [`docs/legacy-identity-compatibility-matrix.md`](docs/legacy-identity-compatibility-matrix.md)。
