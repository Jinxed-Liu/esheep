# eSheepNext

新一代 eSheep+ 的独立 iPhone/iPad 工程。最低系统版本为 iOS/iPadOS 26.1，采用 Swift 6、SwiftUI、SwiftData、Apple 原生 Liquid Glass 与蓝色品牌基线。旧版 `/Users/asiha/Desktop/eSheepPlus` 未被修改。

## 当前本地产品闭环

- 登录页同时提供邮箱验证码注册、账号密码登录和 Sign in with Apple；无牧场首页和牧场设置均提供退出登录。退出会撤销 CloudBase Session，只清除本机登录令牌与 Apple 登录标识，保留牧场缓存和设备身份。
- 多牧场本地隔离：每条业务实体、操作审计和 Outbox 都强制携带 `farmID`。
- 统一命令管道：角色能力校验、业务验证、SwiftData 保存、`DomainOperation` 审计和 Outbox 入队。
- 羊只、圈舍、称重、转群、治疗/疫苗、配种/孕检/产羔、备注和本地搜索。
- 羊群支持耳号/品种搜索、性别/状态/圈舍筛选、排序、分段加载和经命令管道执行的批量转群；单羊可导出包含基础资料与时间线的真实 XLSX。
- 原料库、配方、投喂多原料明细、投喂历史，以及按历史圈舍和真实羊天计算的自由采食分析。
- 只读的确定性本地牧场助手；它不编造数据，也不能直接写入。
- 原生五个 Tab、iPhone/iPad 适配、farm-scoped App Intents 与 Spotlight 索引、通知路由、后台补偿同步、可选牧场 Widget、App Icon、Privacy Manifest、Entitlement 基线和 Emoji 静态扫描。
- 独立 CloudKit 同步层：private/shared `CKSyncEngine`、每牧场 Zone、CKShare、持久化同步状态、完整命令 Outbox、设备签名、能力证书、冲突隔离和异常硬删除检测。
- CloudBase 是唯一生产身份与协作服务：Auth 负责邮箱验证码、密码、刷新、退出与 Apple 自定义登录，文档数据库保存账号、设备、匿名牧场目录、成员、邀请、能力证书和删除审计；养殖业务数据仍只存在 CloudKit。旧 Cloudflare/D1 实现仅保留协议回归，不进入 3.0 运行链路。
- 3.0.0 为免费版本：Release 默认关闭 StoreKit 界面和付费判断，多牧场与已授权生产录入不依赖 Pro 权益；StoreKit 代码保留在默认关闭的构建开关后。
- 云端协作中心：Development 测试牧场启用、系统共享、邀请码、成员与证书、同步、冲突、安全事件和账户删除状态。
- Zone-wide `CKShare(recordZoneID:)`、成员安全 generation 快照、签名 Tombstone、冲突解决操作、压缩照片 `CKAsset`、场主私有加密照片副本与三份 checkpoint 保留策略。
- 每牧场 iCloud 钥匙串恢复密钥、`.esheep-recovery` 恢复包、恢复码包装、恢复点校验与约束检查后的签名恢复操作。
- 设置中心提供 XLSX、CSV、JSON 导入预览、重复与错误报告、稳定幂等键和命令化提交；导出会生成真实 OOXML `.xlsx`，不会把 CSV 改名伪装成工作簿。
- 云缓存安全重建：全 Zone 分页拉取、独立磁盘 staging、签名与摘要校验、照片下载校验、历史重建、单事务业务缓存替换、未确认 Outbox 重放，以及失败后保留旧库和 staging 证据。
- Development 固定种子测试牧场生成器：空牧场首页即可通过正式命令服务生成 10 个圈舍、100 只羊、500 条生产事件和 50 张编号测试图片，不再要求先迁移数据或启用 CloudKit。
- 旧版数据正式导入本机：试迁会话阻断项清零后，可将完整临时牧场原子写入正式 SwiftData；照片在提交前校验 SHA-256，同一来源包重复提交保持幂等，提交失败回滚数据库和资源目录。该入口只写本机，不上传 CloudKit、不修改 eSheep+ 或 Supabase。

## Development 外部状态与仍需事项

这些步骤不能由仓库代码或无签名构建替代，尚未在本机伪造完成状态：

1. 注册并核对 Development、Staging、Production 的 Bundle ID、App Group、CloudKit Container、Sign in with Apple、WeatherKit、Push 与配置文件；3.0.0 不创建或提交订阅产品。
2. 仓库内 CloudBase Gateway 已覆盖邮箱、Apple、刷新、退出、删除、限流、邀请事务与能力证书。新的 Development/Production 部署、CloudBase 自定义登录密钥、Apple Provider 和实时健康检查仍需外部验证；历史 Cloudflare/D1 地址不得写入发行配置。
3. 使用两个真实 iCloud 测试账户完成 Development 环境的 private/shared `CKSyncEngine`、Zone、CKShare、邀请、撤权和恢复验收；Production Schema 仍不部署。
4. 在 App Store Connect 确认 3.0.0 未关联订阅，完成产品页、支持站、隐私政策、服务条款、删除页面与审核账户/演示路径。
5. 按七日清单完成双账号共享、离线同步、冲突、撤权、重装、状态重建、硬删除和照片恢复，并保存每日证据。
6. 新增的 `com.sheepfarm.next.dev.widget`、Staging 和 Production Widget Bundle ID 需要在 Apple Developer 中注册 App Group 能力并生成描述文件；未完成前无签名构建可通过，但带 Widget 的真机安装会被签名门禁拒绝。

当前代码已具备 `CKAsset` 照片传输、加密 checkpoint、区内成员快照、签名删除、业务冲突裁决、独立 SwiftData staging 云缓存重建和正式本机迁移提交。迁移正式提交会写入不可逆的本地锁定标记，服务层拒绝其创建 CloudKit Zone、上传或共享。2026-07-16 已在连接的 iPhone 16 Pro 上通过当时全部 41 项 XCTest；当前自动化基线以 `./tools/verify_local.sh` 的最新结果为准。新增 Widget 描述文件尚未生成时，新增 XCTest 不能在真机执行。CloudBase 远端部署状态以部署清单和实时健康检查为准。真机退出/重登录操作、11 英寸 iPad Pro 最新回归、两个 iCloud 账号互联以及连续七天运行仍需实际操作和自然时间，不能提前标记为通过。

云端准入现在按环境隔离：Development 只允许固定测试牧场，Staging/Production 只允许正式新建牧场；旧版迁移牧场在所有环境中永久保持仅本机。三套构建配置不共享 CloudBase Gateway URL、App Group 或 CloudKit Container。

详细边界与配置步骤见 `docs/云端协作安全设计.md`、`docs/CloudKit_Development配置清单.md` 和 `docs/Development七日验收记录.md`。

## 本地验证

```bash
./tools/verify_local.sh
```

该脚本扫描 Emoji、完整编译 App/Test/Widget（包括 Metal Shader），运行旧 Worker 协议回归，以及 CloudBase Gateway 检查、测试和生产依赖安全审计。运行测试或安装真机需要为 App 与 Widget Bundle ID 配置 Apple 开发团队和 provisioning profile。
