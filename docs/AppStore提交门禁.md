# eSheepNext 3.0.0 App Store 提交门禁

更新时间：2026-07-18

只有所有必需项都有可复核证据时，版本状态才能从“开发完成”改为“可提交审核”。自然时间、真实账号、签名和 App Store Connect 状态不得用本地构建代替。

## 已通过的仓库门禁

- 版本：iOS/iPadOS 26.1，Marketing Version `3.0.0`。
- Debug、Staging、Release 使用独立 Bundle ID、App Group、CloudKit Container、CloudBase Gateway URL 和功能开关；Release 不引用 Development 服务。
- Emoji 扫描通过。
- App、Test、Widget、App Intents 与 Metal Shader 的通用 iOS 无签名 `build-for-testing` 通过。
- CloudBase Gateway 7 项自动化测试、类型/语法检查与生产依赖审计通过；高危/严重漏洞为零。旧 Identity Worker 15 项协议回归测试继续通过，但不属于生产运行链路。
- CloudKit 功能开关和容器名已写入实际 App `Info.plist`；前台启动、回到前台和新增 Outbox 会触发 `CKSyncEngine` 拉取/发送，不再只依赖手动按钮或后台任务。
- 已跟踪文件的常见私钥和生产密钥模式扫描通过；`backups`、本地 xcconfig、Worker `.dev.vars` 均被忽略。
- Cloud 准入、迁移隔离、跨牧场隔离、羊天、自由采食闭合区间、库存反向流水、繁殖不确定性、免费发布模式、云缓存 staging/回滚、XLSX/CSV/JSON 导入与幂等路径已有自动化覆盖。

## Apple Developer 与真机门禁

- [ ] 为 App 与 Widget 的 Development、Staging、Production Bundle ID 注册能力。
- [ ] App 和 Widget 的 App Group 完全一致，并生成有效描述文件。
- [ ] 在正式非 Beta Xcode 上执行全部 122 项 XCTest（2026-07-20 已在 iPhone 16 Pro 使用 Beta Xcode 实跑 122/122，不能替代正式 Xcode 门禁）。
- [ ] iPhone 16 Pro 与 11 英寸 iPad Pro 完成逐页、横竖屏、键盘、Dynamic Type、VoiceOver、深色模式、离线和失败态回归。
- [ ] 使用两个真实 iCloud 账号完成七日 private/shared Zone、邀请、离线、冲突、撤权、重装、缓存重建、照片和最终对账验收。

## 免费发布与生产云门禁

- [x] 3.0.0 Release 设置 `SUBSCRIPTIONS_ENABLED = NO`，隐藏购买、价格、恢复购买和付费提示；多牧场不读取 Pro 权益。
- [ ] App Store Connect 3.0.0 确认未创建、未关联、未提交月度或年度订阅，元数据和截图无收费承诺。
- [ ] 部署并冻结 CloudKit Production Schema，核对 Production Entitlement 和容器。
- [ ] 部署独立 Production CloudBase Auth、文档集合、Gateway 与 Secrets，记录健康检查、版本号、依赖审计和新账号冒烟证据。
- [ ] 完成支持站、隐私政策、服务条款、账户删除页面、截图、审核账号与 Review Notes。

## 最终发行门禁

- [ ] TestFlight 内测与外测无 P0/P1。
- [ ] 正式非 Beta Xcode 生成签名 Archive。
- [ ] 上传验证、隐私清单、出口合规和 App Store Connect 检查全部通过。
- [ ] 保存 Archive、上传验证结果、提交构建号和最终 Git 提交的对应关系。
