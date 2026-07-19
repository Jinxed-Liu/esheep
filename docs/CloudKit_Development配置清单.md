# CloudKit Development 配置清单

## Apple Developer

1. 核对 Development Bundle ID `com.sheepfarm.next.dev` 已启用 Sign in with Apple、iCloud CloudKit 和 WeatherKit。
2. 核对容器 `iCloud.com.sheepfarm.next.dev` 已分配给 Development Bundle ID。
3. 重新生成并安装包含上述能力的开发描述文件。
4. 在 CloudKit Console 选择 Development 环境，不部署 Production Schema。

## CloudBase

1. 为 Development 创建独立 CloudBase 环境，并启用邮箱密码与自定义登录；Staging、Production 不复用环境或密钥。
2. 创建身份集合，生成 CloudBase 自定义登录密钥、Apple client secret 所需私钥、Apple refresh token AES-256-GCM 密钥、频率限制盐和 P-256 能力证书密钥对。
3. 将私钥和盐只写入 CloudBase 函数环境变量；不得进入仓库、xcconfig 或 App 包。
4. 在 `backend/cloudbase-identity-gateway` 运行 `npm run check`、`npm test` 与 `npm run security:audit`，高危或严重漏洞必须为零。
5. 部署 Gateway 后验证健康检查、未授权接口返回 401、邮箱验证码、密码登录、Apple 登录、刷新、退出、删除、邀请单次消费和限流。
6. 把 Gateway HTTPS 地址写入 Debug 构建设置 `IDENTITY_WORKER_URL`；该名称只为 iOS 配置兼容，不代表 Cloudflare Worker。
7. 把能力证书 P-256 公钥 PEM 写入 `CAPABILITY_SIGNING_PUBLIC_KEY_PEM`。

2026-07-18 仓库内 Gateway 自动化与依赖审计已通过；新版本是否已部署以及真实 Apple/CloudBase 全流程必须以实时健康检查和双账号证据为准。历史 Cloudflare/D1 部署不再属于 3.0 运行链路。

## 真机前置检查

1. 场主和成员使用不同 Apple 登录账号与不同 iCloud 账号。
2. iPhone 16 Pro 作为场主设备，第二台 iPhone 或 iPad 作为成员设备。
3. 两台设备均安装同一 Development 构建，并允许 iCloud Drive 与 CloudKit。
4. 使用本次已完成正式提交、云端基线校验和照片摘要校验的迁移牧场；普通空牧场不得进入 Development CloudKit。
5. 等正式牧场状态达到 `synced`、CloudBase 目录达到 `active` 后，完成一次系统共享、邀请码兑换、场主确认、能力证书刷新和离线写入回传。
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
- 不使用未经脱敏和备份确认的生产数据进行破坏性测试。
- 不把本阶段测试结果描述成连续七天稳定性验收。
