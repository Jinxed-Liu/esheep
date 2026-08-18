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
