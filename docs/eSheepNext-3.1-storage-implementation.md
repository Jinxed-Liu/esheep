# eSheepNext 3.1 存储实现边界

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

## 3.0 与 3.1 开关

三个环境的 `SUPABASE_ENABLED` 默认均为 `NO`。因此当前 3.0 构建不会展示
Supabase 账号入口，也不会初始化 Supabase 客户端。为 3.1 环境启用时必须同时：

1. 为 Development、Staging、Production 分别创建独立托管项目。
2. 为对应构建配置填写项目 URL 和 `sb_publishable_...` key。
3. 将该环境的 `SUPABASE_ENABLED` 改为 `YES`。
4. 在项目中应用并验证 `supabase/migrations`，运行双用户 RLS 测试。
5. 完成 Apple provider、邮箱验证、回调 URL 与删除账号任务的服务端配置。

不得把 service-role key、数据库密码或 Apple 私钥写入 iOS 配置。

## 尚需外部环境完成的发布门禁

- 正式非 Beta Xcode 的全量测试、Archive 和签名。
- Development → Staging → Production 三个项目的迁移与 Advisors 清零。
- App Store Server API/Notifications 写入 `entitlements` 的可信服务端处理。
- 北京、上海、广州三网与家庭宽带的登录、刷新、RPC、Storage 和断线恢复测试。
- 双账号/双设备、七日 iCloud、TestFlight、真机照片摘要与 Outbox 归零验收。

这些门禁未通过前，`SUPABASE_ENABLED` 必须保持 `NO`，不得把当前基础设施骨架
标记为 3.1 Production 完成。
