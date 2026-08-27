# 遗留身份兼容调用矩阵

本文记录 2026-08-27 仓库代码中的调用方、路由覆盖和配置边界。它用于判断旧
CloudBase 协作网关与 Cloudflare Identity Worker 能否拆分或删除，不表示任何远端
环境已经部署、健康或具备生产数据权威。

## 运行时解析

`IdentityWorkerClient` 是沿用的类型名；它把所有请求发送到 App 构建设置中的
`IDENTITY_WORKER_URL`，并不根据名称自动选择 Cloudflare Worker。当前客户端协议是
CloudBase 网关 0.4.6 的超集协议，遗留 Worker 只实现其中一部分，因此不能直接替代
当前网关。

| 构建配置 | 仓库内 `IDENTITY_WORKER_URL` | `CLOUD_COLLABORATION_ENABLED` | 结论 |
| --- | --- | --- | --- |
| Development | 空；可由未跟踪的 local xcconfig 覆盖 | 工程默认 `YES` | 仅配置了真实 URL 时进入旧 iCloud 协作路径；不能从仓库推断已部署 |
| Staging | 空；可由未跟踪的 local xcconfig 覆盖 | 工程默认 `NO` | 3.1 Supabase 门禁与旧协作网关分离 |
| Release | 空；可由未跟踪的 local xcconfig 覆盖 | 工程默认 `NO` | 默认不启用旧协作路径；不得重新填入历史 workers.dev 地址 |

Supabase 账号和业务存储由 `SUPABASE_ENABLED`、`FarmStorageProfile` 与当前用户会话
决定；`IDENTITY_WORKER_URL` 不能选择或改变牧场的 3.1 数据 provider。

## iOS 调用方

| 调用领域 | 直接或间接调用方 | 仍使用的能力 |
| --- | --- | --- |
| 登录与会话 | `WelcomeView`、`AccountAccessStatus`、`RootView` 生命周期 | 邮箱验证/注册、密码/Apple 登录、刷新、退出、账户状态 |
| 账户资料 | `AccountAvatarCloudSyncService`、账户设置 | 显示名称、头像 metadata/content/update/delete、删除账户 |
| iCloud 协作 | `CloudCollaborationCenterView`、`CollaborationServiceActors`、`MembershipSnapshotActor` | 设备登记/撤销、牧场登记/激活、邀请、成员、能力证书、安全快照 |
| 同步与恢复 | `CloudSyncActor`、`CloudRebuildActor`、`OwnerFarmRecoveryCoordinator` | 健康检查、账户状态、牧场激活、成员/设备安全 generation |
| Insight 个人密文 | `InsightPersonalSyncActor`、`InsightAssistantSettingsView` | 设备批准/恢复/撤销、密钥 envelope、增量密文同步、恢复包 |

这些调用都必须继续受账号、牧场和当前 authority 边界约束；它们不是新的 3.1
业务事实写入链。

## 路由覆盖

| 路由领域 | CloudBase 网关 0.4.6 | 遗留 Worker | 删除结论 |
| --- | --- | --- | --- |
| health、Apple、密码、refresh、logout | 完整，并含邮箱 verification | 基础子集；无邮箱 verification | 客户端仍调用，不可删除网关路由 |
| account profile/avatar/status/delete | 完整 | 仅 status/delete | 头像与 profile 是网关专有兼容路径 |
| devices register/revoke | 完整 | 完整子集 | 两端协议测试保留 |
| Insight devices/envelopes/sync/recovery | 完整 | 不支持 | 仍有 iOS 调用方，不可删除 |
| farms register/activate | 完整 | 仅 register | `activate` 仍被 `CloudSyncActor` 调用 |
| invites create/redeem/pending/confirm | 完整 | 除 pending 列表外的旧子集 | 快速删除会破坏旧 iCloud 加入闭环 |
| members/capability/security snapshot | 完整 | 旧子集 | 保留至旧协作调用退出并跨版本验证 |

CloudBase 网关公开 endpoint、状态码和 JSON shape 由当前 33 项 Node 测试锁定；遗留
Worker 的 16 项 Vitest 只证明其旧协议子集仍可回归，不证明它能承接当前客户端。

## 配置与发布环境

| 实现 | 数据/运行依赖 | 发布约束 |
| --- | --- | --- |
| CloudBase 网关 | CloudBase Auth 基址、文档集合、Apple 配置、限流盐、能力证书签名配置 | `npm run check`、33 项测试和 npm audit 必须通过；endpoint 与响应 shape 不得随内部拆分改变 |
| 遗留 Worker | Cloudflare D1 `DB`、Apple/Session/加密/能力证书 secrets、`wrangler.jsonc` Development 数据库绑定 | 只保留本地检查与协议回归；历史 workers.dev 地址不得写回 Development/Staging/Release 发行配置，也不得部署为 3.1 Production |

## 允许删除遗留 Worker 的门槛

只有同时满足以下条件，才可另开兼容性批次删除 Worker：

1. 三个构建配置及部署配置均确认不再指向 workers.dev，且取得实际构建设置证据。
2. `IdentityWorkerClient` 的所有存活调用方均由当前 Supabase 或 CloudBase 网关明确承接。
3. 旧版本 App 的最低兼容周期结束，邀请、设备撤销、账户删除和证书撤销没有在途调用。
4. 16 项 Worker fixture 所表达的协议不再承担回归价值，或已迁入网关契约测试。
5. 删除作为独立提交执行，网关 33 项、iOS 完整 XCTest 和双账号旧协作验收全部通过。

在这些证据齐备前，Worker 可以不部署，但不能仅凭目录名称为“legacy”就停止构建、
测试或删除迁移文件。
