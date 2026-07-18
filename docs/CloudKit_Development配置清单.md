# CloudKit Development 配置清单

## Apple Developer

1. 核对 Development Bundle ID `com.sheepfarm.next.dev` 已启用 Sign in with Apple、iCloud CloudKit 和 WeatherKit。
2. 核对容器 `iCloud.com.sheepfarm.next.dev` 已分配给 Development Bundle ID。
3. 重新生成并安装包含上述能力的开发描述文件。
4. 在 CloudKit Console 选择 Development 环境，不部署 Production Schema。

## Cloudflare

1. 在 `backend/identity-worker` 创建 D1 数据库并替换 `wrangler.jsonc` 中的数据库 ID。
2. 生成 Session HMAC 密钥、AES-256-GCM 密钥和 P-256 能力证书密钥对。
3. 使用 `wrangler secret put` 保存 Apple 与 Worker 私钥，不提交 `.dev.vars`。
4. 执行远端 D1 migration，再部署 Worker。
5. 把 Worker HTTPS 地址写入 Debug 构建设置 `IDENTITY_WORKER_URL`。
6. 把能力证书 P-256 公钥 PEM 写入 `CAPABILITY_SIGNING_PUBLIC_KEY_PEM`。

`npm run deploy` 会先检查 D1 ID 与八项必需 Workers Secrets；任一缺失时直接拒绝部署。只允许免费套餐，控制台提示升级或计费时必须停止。

2026-07-16 已完成 Development D1、三份远端 migration、八项 Secrets 和 Worker 部署；`GET /v1/health` 返回版本 `0.2.0-development`、D1 `reachable`。免费套餐使用 Cloudflare 默认 CPU 限制，不配置付费版自定义 CPU 上限。

## 真机前置检查

1. 场主和成员使用不同 Apple 登录账号与不同 iCloud 账号。
2. iPhone 16 Pro 作为场主设备，第二台 iPhone 或 iPad 作为成员设备。
3. 两台设备均安装同一 Development 构建，并允许 iCloud Drive 与 CloudKit。
4. 先创建全新的测试牧场，不选择真实生产牧场，也不使用试迁临时库。
5. 完成一次场主启用、系统共享、邀请码兑换、场主确认、能力证书刷新和离线写入回传。
6. 将每一步时间、账号、设备、Outbox、实体摘要、照片摘要和异常写入 `Development七日验收记录.md`，禁止凭印象填写“通过”。

## 云缓存重建操作

1. App 检测到 private 或 shared `CKSyncEngine` serialization 无法解码时，保留损坏文件、记录损坏标记并暂停对应 scope 自动同步。
2. 在协作中心选择目标牧场和“同步状态损坏”，开始 staging 重建；此时目标牧场只读，旧缓存仍可浏览，未确认 Outbox 可导出。
3. 重建必须完成全 Zone 分页、能力证书和设备签名、operationID、revision、payloadDigest、成员 generation、Tombstone、照片摘要、UUID 引用和业务约束校验。
4. 状态到达“可以切换”后才能提交。提交只替换目标牧场的已确认业务缓存，保留账号、本地配置、其他牧场和未确认 Outbox，并重新应用未确认操作。
5. SwiftData 保存或照片资源切换失败时回滚数据库、删除本次新资源目录，并保留旧库与 staging 证据。
6. 成功后删除损坏 serialization，以空 state 重建对应 engine；engine 重建失败时牧场继续保持只读。

## 禁止事项

- 不修改旧版 eSheep+ 或 Supabase。
- 不把 CloudKit Development 数据部署为 Production。
- 不导入真实牧场备份。
- 不把本阶段测试结果描述成连续七天稳定性验收。
