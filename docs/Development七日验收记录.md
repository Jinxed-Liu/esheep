# eSheepNext Development 七日验收记录

本记录只用于本次完成正式提交和云端基线校验的迁移牧场。没有实际执行、截图、日志与摘要证据的项目必须保留“未执行”，不得提前标记通过。

## 固定环境

- Bundle ID：`com.sheepfarm.next.dev`
- CloudKit Container：`iCloud.com.sheepfarm.next.dev`
- CloudKit：Development
- 场主设备：iPhone 16 Pro
- 成员设备：11 英寸 iPad Pro
- 场主 Apple/iCloud 账号：待填写
- 成员 Apple/iCloud 账号：待填写
- CloudBase Gateway URL 与版本：待部署后填写
- CloudBase 环境与部署 ID：待部署后填写
- 正式迁移牧场 ID：待填写
- 迁移提交 ID 与基线摘要：待填写

## 每日证据模板

每次记录：开始与结束时间、两台设备系统版本、网络状态、CloudBase Gateway health、security generation、最新 checkpoint ID、Outbox 各状态数量、两端权威实体数量/最高 revision/汇总摘要、照片数量/摘要、冲突与安全事件。

## 第 1 日：部署与初始共享

- 状态：未执行
- 部署 CloudBase 身份集合、Gateway、Auth Provider、Apple/能力证书密钥并完成生产依赖审计。
- 两账号 Apple 登录、场主建立 Zone-wide Share、邀请码兑换、参与者确认。
- 成员快照 generation 与初始 checkpoint 一致。
- 第一台设备的迁移实体数量、关键羊只状态和照片摘要与迁移提交清单一致。

## 第 2 日：离线生产与照片

- 状态：未执行
- 成员离线新增称重、转群、投喂、治疗和照片。
- 联网后 Outbox 全部 confirmed，operationID 无重复，50 张照片 payloadDigest 一致。

## 第 3 日：并发冲突

- 状态：未执行
- 制造普通备注、受保护羊只字段、库存和繁殖冲突。
- 场主解决后业务模型真实变化；负库存、重复耳号、循环系谱和重叠批次被阻断。

## 第 4 日：角色与撤权

- 状态：未执行
- 管理员与员工能力矩阵逐项验证。
- 撤权前 checkpoint、CloudBase 撤销、generation 递增、成员快照、CKShare 移除、撤权后 checkpoint 顺序有日志。
- 被撤权设备的新操作不得被接受。

## 第 5 日：重装与恢复密钥

- 状态：未执行
- 卸载重装后核对 iCloud Keychain 恢复密钥。
- 使用 `.esheep-recovery` 与一次性恢复码恢复；错误码、损坏包和错误牧场全部拒绝。

## 第 6 日：状态重建与异常删除

- 状态：未执行
- 破坏 CKSyncEngine state 后保留未确认 Outbox，完成 staging 拉取、校验与原子替换演练。
- 无 Tombstone 硬删除实体后从 checkpoint 生成 recovery operation。
- 删除共享照片后从场主恢复区恢复，下载摘要一致。

## 第 7 日：全量对账

- 状态：未执行
- 两端权威实体数量、revision、摘要一致；Outbox 全部 confirmed。
- 核对共享区与恢复区存储估算、全部审计、安全事件和撤权重试。
- iPhone 16 Pro 与 iPad 逐页布局、动态字体、键盘和安全区通过。
- 附 CloudBase Gateway 测试、完整 XCTest、产品 Emoji 扫描与七日结论。

## 当前自动化基线

- 2026-07-16：Worker TypeScript 检查通过，Vitest 14 项通过；账号注册、密码登录、重复账号、连续错误锁定和退出撤销当前 Session 均有覆盖。
- 2026-07-16：iPhone 16 Pro 真机 XCTest 41 项通过，0 失败；独立 SwiftData staging Store、正式本机迁移原子提交、迁移牧场永久 localOnly 门禁与退出后的身份状态重置测试均已通过。
- 2026-07-16：11 英寸 iPad Pro 已登记到 Development provisioning，新增 staging 测试前的真机 XCTest 34 项通过，0 失败；最新 35 项复验因设备上锁中止，待解锁后重跑。
- 2026-07-16：Debug 模拟器构建、Release 无签名真机构建与 `build-for-testing` 通过，产品 Emoji 扫描通过。
- 2026-07-16：历史 Cloudflare/D1 Identity Worker 曾完成 Development 部署，但已退出 3.0 运行链路，不能作为当前 CloudBase 验收证据。签名 App 已安装到 iPhone 16 Pro；CloudBase 新 Gateway 的真实账号全流程和第 1 日计时尚未完成。
- 2026-07-18：当前 CloudBase Development 地址健康检查可达，未授权账户接口返回 401；但 `/v1/auth/apple` 仍返回旧版 `apple_cloudbase_migration_pending` 503，证明仓库内 0.3.0 Gateway 尚未部署。该项保持发布阻断。
- 2026-07-19：使用 CloudBase CLI 的完整 COS 通道部署 Gateway 0.3.0，远端函数为 Active/Available，15 项运行配置完整且健康检查返回 200/0.3.0。Apple 路由的无效凭证返回 401 `apple_authentication_failed`，旧迁移响应已消失；CloudBase 自定义登录票据真实换回 access/refresh session，Apple client secret 向 Apple 验证返回预期 `invalid_grant`。首次限流文档不存在曾导致邮箱入口 500，补充 SDK `DOCUMENT_NOT_FOUND` 适配和回归测试后重新部署，邮箱格式错误返回 400、错误密码返回 400、未授权账户接口返回 401。部署探针账号已删除。真实 Apple 授权弹窗和邮箱验证码收取仍待真机交互。
- 2026-07-19：迁移牧场云端启动所需的 Gateway 0.3.1 已通过完整 COS 通道部署到同一 Development 环境。健康检查返回 200/0.3.1；新增激活接口存在，未授权调用返回 401 `missing_access_token`。该证据只证明服务版本和鉴权边界，不替代真实迁移包上传、CloudKit 摘要核对或第二台设备重建。
- 2026-07-19：真机迁移首次暴露 JSON UUID 大写、URL UUID 小写造成 CloudBase 文档键不一致；Gateway 0.3.2 统一牧场 UUID 后通过 13/13 测试并部署 Development。该项仍需等待当前真机基线完成上传与摘要核对。
- 2026-07-18：iPhone 16 Pro 签名构建实际执行全部 82 项 XCTest，最终 82 项通过、0 失败。期间发现并修复 CSV 日期解析受系统区域设置影响的问题；11 英寸 iPad 与双账号云端流程仍未执行。
- 两个真实 Apple/iCloud 账号互联和第 1 至第 7 日云端记录：未执行。
