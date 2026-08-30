# eSheep+ 3.1.0 中国及全球 App Store 提交门禁

更新时间：2026-08-27

只有全部必需项都有可复核证据时，状态才能从“Release Candidate”改为
“可提交审核”。本地编译不能替代线上平台、真实网络、真机、TestFlight、
签名 Archive 或 App Store Connect 证据。

## 代码与构建

- [x] 建立 `codex/3.1-release`，并在仓库外保存 bundle、脏工作树归档、状态和 SHA-256。
- [x] App/Widget Marketing Version 统一为 `3.1.0`，初始构建号为 `1`。
- [x] Release/Staging `SUPABASE_ENABLED=YES`，全部环境 `SUBSCRIPTIONS_ENABLED=NO`。
- [x] Production Bundle ID 为 `com.sheepfarm.ios` 与 `com.sheepfarm.ios.widget`。
- [x] 修复 Release Swift 6 隔离编译错误。
- [ ] 正式非 Beta Xcode 编译 Debug、Staging、Release 的 App、Widget、App Intents 和测试 Target。
- [ ] 正式 Xcode 全量 XCTest：发现数大于 0，0 失败、0 跳过，xcresult 完整可读。
- [ ] Emoji、凭据、依赖漏洞、隐私清单和 `git diff --check` 全部通过。

## Supabase 平台

- [x] 仓库配置关闭匿名登录、使用短时 JWT，并明确 Data API 最小权限。
- [x] TMR 数据协议版本为 1；设备注册上报版本，TMR 写入具有稳定升级错误。
- [x] 迁移不再修改已锁定的 `realtime` schema；按 `supabase/REALTIME_SETUP.md` 配置和验收。
- [x] 免费首发不再以 `entitlements` 限制 Supabase 建场、迁移和写入。
- [x] 已加入幂等账号删除任务、service-role 专用 RPC、Edge Function、重试退避和历史匿名化约束。
- [ ] 安装 Supabase CLI 与 Docker，在空库重放全部迁移并执行 pgTAP；当前本机两者均缺失。
- [ ] 创建新加坡 Development、Staging、Production 三项目；Production 为 Pro + PITR、双 Owner、MFA、SSL 和告警。
- [ ] 三环境分别完成 Apple/邮箱 Auth、回调 URL、自有 SMTP、中英文邮件、Secrets、Storage、Realtime 和 Data API 配置。
- [ ] Staging 重放和负载测试后只向前部署 Production；Security Advisor 高危/严重项与阻塞性能项清零。

## 本地化、隐私、法律和网站

- [x] 已生成 App/Widget String Catalog；Info.plist 权限用途描述已有简中和英文资源。
- [ ] `tools/check_localizations.py` 必须通过；当前英文 String Catalog 尚未完整翻译。
- [x] Privacy Manifest 已声明 Required Reason API，并按当前审计补充实际地址、
  AI 音频、其他使用数据和保守的其他诊断数据。
- [ ] 正式 Archive 聚合隐私报告与 `docs/3.1-隐私数据清单.md`、商店问卷和公开政策一致。
- [x] App 内完成分层告知、条款/隐私显式同意、境外提供单独同意、版本留痕，
  AI 另行同意且可撤回；待迁移部署和真机验收。
- [x] 中英文完整条款、隐私、AI/境外告知与十个双语网页已有未发布模板。
- [x] 已完成官方 24 项小型个人信息处理者自查映射、影响评估、内部制度、
  应急预案、权利请求与培训/演练模板；尚待真实负责人签署和演练。
- [ ] 购买正式域名、配置 HTTPS/支持邮箱、替换模板占位符，并完成中国三地和海外探测。
- [ ] 完成简中/英文的 6.9 英寸 iPhone 与 13 英寸 iPad 真实截图。

## 数据、真机、网络和 TestFlight

- [ ] 五类牧场完成逐牧场迁移、四个中断点续跑和双设备最终摘要对账。
- [ ] 跨场、越权、撤权离线写回、错误 farmID、过期邀请、旧 TMR 协议、伪造 JWT/路径和 Storage 覆盖均被拒绝。
- [ ] iPhone 16 Pro、iPhone Air、11/13 英寸 iPad 完成简中/英文全路径及无障碍、离线和权限拒绝回归。
- [ ] Development 两日破坏性测试、Staging 连续七日双账号双设备测试完成。
- [ ] 北京、上海、广州三网/家庭宽带以及东亚、欧洲、北美完成生产网络门禁。
- [ ] Production 内部 TestFlight 48 小时、外部 TestFlight 连续七日通过，无 P0/P1、无数据丢失、Outbox 归零。

## 提交与发布

- [ ] 正式非 Beta Xcode 生成并 Validate 签名 Archive。
- [ ] App Store Connect 无 IAP/订阅；双语元数据、隐私、年龄、出口合规、免费价格、地区、审核账号和 Review Notes 完整。
- [ ] 保存 commit、Archive、构建号、迁移版本、Supabase project ref、隐私报告和 TestFlight 的一一映射。
- [ ] 审核通过后保持手动发布；发布前创建 PITR 恢复点并检查 Auth、SMTP、Storage、Realtime、网站和告警。
- [ ] 发布后 72 小时监控关键生产指标；数据库只向前修复，客户端问题发布 `3.1.1`。
