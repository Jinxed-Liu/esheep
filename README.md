# eSheepNext

新一代 eSheep+ 的独立 iPhone/iPad 工程。最低系统版本为 iOS/iPadOS 26.1，采用 Swift 6、SwiftUI、SwiftData、Apple 原生 Liquid Glass 与蓝色品牌基线。旧版 `/Users/asiha/Desktop/eSheepPlus` 未被修改。

## 当前本地产品闭环

- 登录页同时提供邮箱验证码注册、账号密码登录和 Sign in with Apple；无牧场首页和牧场设置均提供退出登录。退出会撤销 CloudBase Session，只清除本机登录令牌与 Apple 登录标识，保留牧场缓存和设备身份。
- 已保存的本地工作区不再绕过真实会话门禁：只有持久化 CloudBase Session 有效，且 Apple 账号主体校验一致时才进入牧场；服务不可用或账号主体不一致会明确拒绝登录，不再显示为“迁移中”后继续使用本地身份。
- 多牧场本地隔离：每条业务实体、操作审计和 Outbox 都强制携带 `farmID`。
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
- 独立 CloudKit 同步层：private/shared `CKSyncEngine`、每牧场 Zone、CKShare、持久化同步状态、完整命令 Outbox、设备签名、能力证书、冲突隔离和异常硬删除检测。
- CloudBase 是唯一生产身份与协作服务：Auth 负责邮箱验证码、密码、刷新、退出与 Apple 自定义登录，文档数据库保存账号、设备、匿名牧场目录、成员、邀请、能力证书和删除审计；养殖业务数据仍只存在 CloudKit。旧 Cloudflare/D1 实现仅保留协议回归，不进入 3.0 运行链路。
- 3.0.0 为免费版本：Release 默认关闭 StoreKit 界面和付费判断，多牧场与已授权生产录入不依赖 Pro 权益；StoreKit 代码保留在默认关闭的构建开关后。
- 云端协作中心：正式迁移牧场云端状态、系统共享、邀请码、成员与证书、同步、冲突、安全事件和账户删除状态。
- Zone-wide `CKShare(recordZoneID:)`、成员安全 generation 快照、签名 Tombstone、冲突解决操作、压缩照片 `CKAsset`、场主私有加密照片副本与三份 checkpoint 保留策略。
- 每牧场 iCloud 钥匙串恢复密钥、`.esheep-recovery` 恢复包、恢复码包装、恢复点校验与约束检查后的签名恢复操作。
- 设置中心提供 XLSX、CSV、JSON 导入预览、重复与错误报告、稳定幂等键和命令化提交；导出会生成真实 OOXML `.xlsx`，不会把 CSV 改名伪装成工作簿。
- 设置中心另提供版本化 `FarmBackupEnvelopeV1` 完整本地备份。恢复先在独立临时 SwiftData 容器中校验 checksum、引用、耳号和历史状态，只允许写入空牧场，重复恢复保持幂等；XLSX/CSV 仍只作为人工查看和表格交换。
- 云缓存安全重建：全 Zone 分页拉取、独立磁盘 staging、签名与摘要校验、照片下载校验、历史重建、单事务业务缓存替换、未确认 Outbox 重放，以及失败后保留旧库和 staging 证据。
- 旧版牧场正式导入：阻断项清零后，将临时牧场、照片和版本化云端基线原子写入正式 SwiftData；同一来源包重复提交保持幂等，失败回滚数据库和资源目录。Development 在联网后自动续传至用户 iCloud，始终不修改 eSheep+ 或 Supabase。

## 当前阶段边界与外部状态

这些步骤不能由仓库代码或无签名构建替代，尚未在本机伪造完成状态：

1. Debug/Development 已启用正式迁移牧场的 iCloud 双设备同步与成员邀请入口；Staging 与 Release 继续关闭。真实双账号邀请、撤权、订阅、TestFlight 和 App Store 工作仍需单独验收。
2. 仓库内 CloudBase Gateway 0.3.3 已覆盖邮箱、Apple、刷新、退出、删除、限流、账户显示名称修改、迁移牧场 `provisioning → active` 目录状态，以及牧场 UUID 大小写统一。2026-07-19 已向 Development 完整 COS 部署的仍是 0.3.2；0.3.3 的账户名称接口尚待部署。真实 Apple 系统授权、邮箱验证码注册和迁移牧场双设备重建仍需在真机分别完成交互验收。
3. 登录成功后的业务写入只依赖本机 SwiftData；断网、CloudKit 关闭和重启不应阻断建羊、称重、转群、离场、修正、撤销、查询和备份恢复。
4. 新增的 `com.sheepfarm.next.dev.widget` Bundle ID 仍需要有效描述文件才能在连接设备上运行 XCTest；无签名 App/Test/Widget 编译不受此限制。

当前自动化基线以 `./tools/verify_local.sh` 的最新结果为准；真实登录、迁移包上传、同一场主双设备重建、断网续传和照片对账仍必须在两台真实 iCloud 设备上取得证据，不能由编译或模拟响应代替。

2026-07-20 系谱与繁殖闭环已在 iPhone 16 Pro（iOS 27.0）执行全部 128 项 XCTest，128 项通过、0 失败、0 跳过；系谱、旧载荷与 checkpoint 全历史恢复聚焦回归 7/7 通过。`build-for-testing`、旧 Worker 15/15、CloudBase Gateway 16/16、Emoji 扫描与依赖审计以 `./tools/verify_local.sh` 的最新成功结果为准。11 英寸 iPad 的完整页面回归、两台 Development 设备的真实 CloudKit 关系/供体同步，以及 Gateway 0.3.3 部署仍未完成。

云端准入按环境隔离：Development 只允许具有完整迁移提交、基线摘要和照片校验的正式迁移牧场，不再存在固定种子测试牧场路径；Staging/Production 云功能仍由构建开关关闭。迁移目录在完整上传前保持 provisioning，第二台设备和受邀成员只能发现 active 牧场。

详细边界与配置步骤见 `docs/云端协作安全设计.md`、`docs/CloudKit_Development配置清单.md` 和 `docs/Development七日验收记录.md`。

## 本地验证

```bash
./tools/verify_local.sh
```

该脚本扫描 Emoji、完整编译 App/Test/Widget（包括 Metal Shader），运行旧 Worker 协议回归，以及 CloudBase Gateway 检查、测试和生产依赖安全审计。运行测试或安装真机需要为 App 与 Widget Bundle ID 配置 Apple 开发团队和 provisioning profile。
