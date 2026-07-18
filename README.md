# eSheepNext

新一代 eSheep+ 的独立 iPhone/iPad 工程。最低系统版本为 iOS/iPadOS 26.1，采用 Swift 6、SwiftUI、SwiftData、Apple 原生 Liquid Glass 与蓝色品牌基线。旧版 `/Users/asiha/Desktop/eSheepPlus` 未被修改。

## 当前本地产品闭环

- 登录页同时提供账号注册、账号密码登录和 Sign in with Apple；无牧场首页和牧场设置均提供退出登录。退出会撤销当前服务器 Session，只清除本机登录令牌与 Apple 登录标识，保留牧场缓存和设备身份。密码凭据只在身份 Worker 以加盐 PBKDF2 派生值保存。
- 多牧场本地隔离：每条业务实体、操作审计和 Outbox 都强制携带 `farmID`。
- 统一命令管道：角色能力校验、业务验证、SwiftData 保存、`DomainOperation` 审计和 Outbox 入队。
- 羊只、圈舍、称重、转群、治疗/疫苗、配种/孕检/产羔、备注和本地搜索。
- 原料库、配方、投喂多原料明细、投喂历史，以及按历史圈舍和真实羊天计算的自由采食分析。
- 只读的确定性本地牧场助手；它不编造数据，也不能直接写入。
- 原生五个 Tab、iPhone/iPad 适配、App Intents 快捷入口、App Icon、Privacy Manifest、Entitlement 基线和 Emoji 静态扫描。
- 独立 CloudKit 同步层：private/shared `CKSyncEngine`、每牧场 Zone、CKShare、持久化同步状态、完整命令 Outbox、设备签名、能力证书、冲突隔离和异常硬删除检测。
- 独立 Cloudflare Workers + D1 身份服务源码，覆盖账号注册、密码登录、Apple 服务端验证、会话轮换、设备公钥、邀请、角色证书、账户删除与安全审计；不保存牧场业务数据。
- 云端协作中心：Development 测试牧场启用、系统共享、邀请码、成员与证书、同步、冲突、安全事件和账户删除状态。
- Zone-wide `CKShare(recordZoneID:)`、成员安全 generation 快照、签名 Tombstone、冲突解决操作、压缩照片 `CKAsset`、场主私有加密照片副本与三份 checkpoint 保留策略。
- 每牧场 iCloud 钥匙串恢复密钥、`.esheep-recovery` 恢复包、恢复码包装、恢复点校验与约束检查后的签名恢复操作。
- 云缓存安全重建：全 Zone 分页拉取、独立磁盘 staging、签名与摘要校验、照片下载校验、历史重建、单事务业务缓存替换、未确认 Outbox 重放，以及失败后保留旧库和 staging 证据。
- Development 固定种子测试牧场生成器：空牧场首页即可通过正式命令服务生成 10 个圈舍、100 只羊、500 条生产事件和 50 张编号测试图片，不再要求先迁移数据或启用 CloudKit。
- 旧版数据正式导入本机：试迁会话阻断项清零后，可将完整临时牧场原子写入正式 SwiftData；照片在提交前校验 SHA-256，同一来源包重复提交保持幂等，提交失败回滚数据库和资源目录。该入口只写本机，不上传 CloudKit、不修改 eSheep+ 或 Supabase。

## Development 外部状态与仍需事项

这些步骤不能由仓库代码或无签名构建替代，尚未在本机伪造完成状态：

1. 注册并核对 Development、Staging、Production 的 Bundle ID、App Group、CloudKit Container、Sign in with Apple、WeatherKit、Push、In-App Purchase 与配置文件。
2. Development Identity Worker、D1、八项 Secrets、Sign in with Apple Key、远端 migration、健康检查和本地 Debug 配置已完成。Worker 地址为 `https://esheep-next-identity.esheep-next-dev.workers.dev`；私钥不进入仓库，本地公开配置由被忽略的 `DevelopmentEnvironment.local.xcconfig` 提供。
3. 使用两个真实 iCloud 测试账户完成 Development 环境的 private/shared `CKSyncEngine`、Zone、CKShare、邀请、撤权和恢复验收；Production Schema 仍不部署。
4. 在 App Store Connect 创建月度/年度订阅、产品页、支持站、隐私政策、服务条款、删除页面与审核账户/演示路径。
5. 按七日清单完成双账号共享、离线同步、冲突、撤权、重装、状态重建、硬删除和照片恢复，并保存每日证据。

当前代码已具备 `CKAsset` 照片传输、加密 checkpoint、区内成员快照、签名删除、业务冲突裁决、独立 SwiftData staging 云缓存重建和正式本机迁移提交。迁移正式提交会写入不可逆的本地锁定标记，服务层拒绝其创建 CloudKit Zone、上传或共享。2026-07-16 已在连接的 iPhone 16 Pro 上通过全部 41 项 XCTest，并通过 14 项 Worker 测试；Development Worker `0.2.1-development` 已真实部署，D1 健康检查为 `reachable`，带真实 Worker URL 的签名构建已安装并启动。真机退出/重登录操作、11 英寸 iPad Pro 最新回归、两个 iCloud 账号互联以及连续七天运行仍需实际操作和自然时间，不能提前标记为通过。

详细边界与配置步骤见 `docs/云端协作安全设计.md`、`docs/CloudKit_Development配置清单.md` 和 `docs/Development七日验收记录.md`。

## 本地验证

```bash
./tools/verify_local.sh
```

该脚本扫描 Emoji，并用已安装的 Xcode Beta 进行无签名 `build-for-testing`。运行测试或安装真机需要为当前 Development Bundle ID 配置 Apple 开发团队和 provisioning profile。
