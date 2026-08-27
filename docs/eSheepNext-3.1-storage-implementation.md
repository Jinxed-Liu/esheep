# eSheepNext 3.1 存储实现边界

本文是 3.1 存储、同步和云端权威的唯一当前架构说明。README 中标为
“3.0 历史记录”的内容以及旧 CloudKit/CloudBase 设计文档只用于解释迁移来源，
不得用于改变 3.1 写入路由或发布判断。

## 可执行职责矩阵

| 组件 | 当前职责 | 明确禁止 |
| --- | --- | --- |
| 本地 SwiftData 投影 | 保存离线工作副本、历史事实、审计、Outbox、同步状态和页面所需本地投影；所有 UI 查询都受当前账号与牧场边界约束 | 不直接决定远端 provider；模型对象不跨 actor 传递 |
| `FarmCommandService` | 唯一业务写入 façade；在同一受控命令中完成能力校验、业务验证、本地保存、`DomainOperation` 和需要时的 Outbox 入队 | 视图、同步器、Web 或优化快照不得绕过它写业务事实 |
| `FarmPersistenceActor` | 在 SwiftData actor 隔离内执行查询、同步应用、合并、重建和维护；向调用方返回值类型快照 | 不接收或返回跨 actor 使用的 SwiftData 模型对象；不改变业务写入入口 |
| `DomainOperation` / Outbox | 保存可审计、可重试、幂等的操作；创建时钉住 `deliveryProvider` 与 `authorityGeneration` | 不按当前 UI、登录状态或后来切换的 provider 静默重写路由 |
| `FarmStorageProfile` / `FarmStorageRouter` | 为每个真实 V3 牧场记录唯一存储模式、权威 generation 和迁移状态；计算命令应使用的远端路由 | 不允许一个牧场同时存在两个远端权威；不由页面缓存推断权威 |
| `FarmStorageTransitionCoordinator` | 准备迁移、校验目标基线并通过 `commitAuthority` 原子提交权威切换 | 失败后不得静默回滚源端或跳过 generation 增长 |
| Supabase | 当存储配置选择 `.supabase` 时承担 3.1 Auth、成员/RLS、业务实体、操作、Storage、Realtime、checkpoint 与读取 RPC | iOS/Web 只使用 publishable key 和用户会话；不得用 service role 绕过租户隔离或从客户端改变 RLS |
| CloudKit | 当存储配置选择 `.iCloud` 时承担对应牧场的 private/shared 同步；继续读取旧版无 provider Outbox，并作为受控迁移来源 | 不处理明确钉住 `.supabase` 的 Outbox；不得自动成为所有牧场的默认权威 |
| CloudBase 协作网关 / `IdentityWorkerClient` | 保留旧 iCloud 协作身份、设备、邀请、能力证书、头像和仍有调用方的 Insight 个人密文路径；当前调用方与路由见 [`legacy-identity-compatibility-matrix.md`](legacy-identity-compatibility-matrix.md) | 不替代 `FarmStorageProfile` 为 3.1 业务数据选 provider；仍有调用方时不得删除路由或停测 |
| 遗留身份 Worker | 只保留协议回归和兼容性证据；其路由只是 CloudBase 网关当前协议的子集 | 不进入新的 3.1 业务写入链，不得重新写入发行配置，也不得仅因“遗留”标签未经调用矩阵就删除 |
| React Web | 以用户会话和 RLS 只读加载当前页面所需投影，可保存本机草稿 | 不新增业务写入链，不缓存或展示其他牧场数据，不改变 iOS Outbox 协议 |

任何性能缓存、快照、索引或只读 RPC 都只能缩短读取路径；它们不能成为新的
业务事实来源，也不能扩大账号、成员、牧场、provider 或 generation 的访问范围。

## 不变量

- `FarmCommandService` 是业务写入的唯一入口。
- 每个真实 V3 牧场必须且只能有一个 `FarmStorageProfile`。
- `.localOnly` 不创建远端绑定，也不生成可上传 Outbox。
- 云模式的每条 Outbox 固化 `deliveryProvider` 和
  `authorityGeneration`，同步器不得根据当前 UI 状态改写路由。
- 迁移切换前，源端仍是唯一权威；迁移期新操作只进入目标队列。
- `commitAuthority` 是唯一能改变 mode 和增加 generation 的入口。
- 提交后失败只能续跑目标端，不能自动回滚源端。
- CloudKit 同步器只读取 iCloud 或旧版无 provider 的 Outbox。
- Supabase 客户端只使用 publishable key；所有业务表、RPC、Storage 和
  Realtime 均由 `auth.uid()` 与 `farm_members` 授权。

## 3.1 环境开关

Staging 与 Release 的 `SUPABASE_ENABLED` 固定为 `YES`，Development 默认
为 `NO` 并可由本地配置切换。启用的每个环境必须同时：

1. 为 Development、Staging、Production 分别创建独立托管项目。
2. 为对应构建配置填写项目 URL 和 `sb_publishable_...` key。
3. 从空库应用并验证 `supabase/migrations`，运行双用户/三角色 RLS、
   Storage、Realtime 和 RPC 测试。
4. 完成 Apple provider、邮箱验证、回调 URL、自有 SMTP 与删除账号
   Edge Function 的服务端配置。

不得把 service-role key、数据库密码或 Apple 私钥写入 iOS 配置。

## 尚需外部环境完成的发布门禁

- 正式非 Beta Xcode 的全量测试、Archive 和签名。
- Development → Staging → Production 三个项目的迁移与 Advisors 清零。
- 北京、上海、广州三网与家庭宽带的登录、刷新、RPC、Storage 和断线恢复测试。
- 双账号/双设备、七日 Staging、TestFlight、真机照片摘要与 Outbox 归零验收。

这些门禁未通过前，不得上传 Production 数据、提交 App Store 或把当前
基础设施骨架标记为 3.1 Production 完成。
