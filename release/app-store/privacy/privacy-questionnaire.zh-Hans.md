# eSheep+ App Store Connect 隐私问卷（简体中文工作底稿）

问卷版本：2026.09.01  
对应 App：3.1.0  
结论状态：**数据流已审计；正式提交前仍需按 Production Supabase、SMTP、MiMo 当期行为和 Xcode Archive 聚合隐私报告复核。**

## Apple 口径

- “收集”指数据从设备传出，并由开发者或第三方保留超过实时完成请求所需的时间。
- 仅在设备内处理的 SwiftData、Keychain、Face ID/Touch ID 模板、Nearby Interaction 距离、未上传的导入文件和用户写入系统日历/提醒事项，不在问卷中声明为“收集”。
- 第三方伙伴（Supabase、Apple、SMTP、MiMo）通过 App 收集的数据必须纳入回答。
- 所有“是”的类别均选择：**用于 App 功能、关联用户、不用于跟踪**。没有广告、第三方广告、开发者营销或跨 App/网站跟踪目的。

## 一、数据类型选择

| App Store 数据类别 | 是否收集 | 是否关联用户 | 是否用于跟踪 | 用途 | 真实数据流与边界 |
|---|---:|---:|---:|---|---|
| 联系信息 → 姓名 | 是 | 是 | 否 | App 功能 | 显示名、Apple 允许返回的姓名，用于账号和成员显示 |
| 联系信息 → 电子邮件地址 | 是 | 是 | 否 | App 功能 | 注册、验证、找回、安全通知、权利请求 |
| 联系信息 → 实际地址 | 是 | 是 | 否 | App 功能 | 用户主动填写的牧场地址文本；可能等同个人经营地址 |
| 联系信息 → 电话号码 | 否 | — | — | — | 当前账号和业务流程不要求自然人电话；自由备注中偶然录入的内容归“其他用户内容” |
| 健康与健身 | 否 | — | — | — | 羊只健康不是自然人的 HealthKit/医疗健康；不得在 App Store 问卷误报成人类健康数据 |
| 财务信息 | 否 | — | — | — | 牧场成本/库存为用户业务内容，不收集银行卡、信用、支付或工资账户；App 无 IAP |
| 位置 → 精确位置 | 是 | 是 | 否 | App 功能 | 用户主动保存牧场坐标和请求对应天气；非持续后台追踪 |
| 位置 → 粗略位置 | 否（被精确位置覆盖） | — | — | — | 不另行持续收集；基础设施可能从 IP 推断地区，按 Device ID/诊断的保守口径复核 |
| 敏感信息 | 否 | — | — | — | 不设计收集种族、宗教、政治、工会、性取向等；若自由文本误录，仍作为用户内容处理但不是产品要求的数据字段 |
| 联系人 | 否 | — | — | — | 不读取系统通讯录 |
| 用户内容 → 电子邮件或短信 | 否 | — | — | — | 不读取设备邮件或短信；我们发送的验证邮件不等于收集用户邮件内容 |
| 用户内容 → 照片或视频 | 是 | 是 | 否 | App 功能 | 羊只、病症、耳标、票据和 AI 图片；只处理用户拍摄/选择的项目 |
| 用户内容 → 音频数据 | 是 | 是 | 否 | App 功能 | 用户主动录制并发送给 MiMo 的 AI 语音；本机长期保留默认关闭 |
| 用户内容 → 游戏内容 | 否 | — | — | — | 非游戏 |
| 用户内容 → 客户支持 | 是 | 是 | 否 | App 功能 | 用户向支持/隐私邮箱提交的通信和最少身份核验信息；并入用户内容 |
| 用户内容 → 其他用户内容 | 是 | 是 | 否 | App 功能 | 牧场、羊只、成员、健康繁殖、饲喂、TMR、备注、导入、AI 提示/响应和操作历史 |
| 浏览历史 | 否 | — | — | — | App 不监控 Safari/其他浏览；MiMo 官方额度登录 WebView 仅用于该功能，不形成 eSheep 浏览画像 |
| 搜索历史 | 否 | — | — | — | App 内牧场搜索主要本机完成；不建立独立远端搜索画像 |
| 标识符 → 用户 ID | 是 | 是 | 否 | App 功能 | Supabase Auth ID、eSheep account ID、成员/审计主体标识 |
| 标识符 → 设备 ID | 是 | 是 | 否 | App 功能 | App 生成设备 UUID、公钥登记、服务 IP/安全关联；不使用 IDFA |
| 购买项目 | 否 | — | — | — | 3.1 免费，无 IAP/订阅；MiMo Token Plan 由用户与 MiMo 直接交易 |
| 使用数据 → 产品交互 | 否 | — | — | — | 无行为分析 SDK；普通业务操作属于“其他用户内容”，不做产品行为画像 |
| 使用数据 → 广告数据 | 否 | — | — | — | 无广告 |
| 使用数据 → 其他使用数据 | 是 | 是 | 否 | App 功能 | MiMo 模型/Token 使用状态、同步/删除任务状态及安全用量记录；不用作广告或用户画像 |
| 诊断 → 崩溃数据 | 否 | — | — | — | 未集成第三方崩溃收集；正式 Archive 再核对打包依赖 |
| 诊断 → 性能数据 | 否 | — | — | — | 当前性能追踪为开发/本机代码，不应上传 Production；若上线遥测必须先改标签 |
| 诊断 → 其他诊断数据 | 是（保守） | 是 | 否 | App 功能 | 认证、同步、数据库、存储和邮件的错误码、请求时间、IP/标识及必要安全日志 |
| 周围环境 | 否 | — | — | — | 相机内容由用户主动拍摄，未建立环境扫描数据库 |
| 身体 | 否 | — | — | — | 不收集手部/头部运动或人体深度信息 |
| 其他数据 | 否 | — | — | — | 已归入上述具体类别 |

## 二、数据用途页面统一选择

对所有标“是”的类别：

- [x] App 功能（账号、同步、协作、AI、客服、安全、防欺诈、恢复）
- [ ] 第三方广告
- [ ] 开发者广告或营销
- [ ] 分析（未使用产品行为分析；仅服务运行和安全诊断）
- [ ] 产品个性化（AI 只回答用户当前请求，不构成广告/推荐画像）
- [ ] 其他目的

## 三、跟踪问题

- 是否将用户或设备数据与其他公司为广告、广告测量或数据经纪目的的数据关联：**否**。
- 是否与数据经纪商共享：**否**。
- 是否使用 IDFA 或申请 AppTrackingTransparency：**否**。
- `NSPrivacyTracking`：**false**；`NSPrivacyTrackingDomains`：空数组。

## 四、可选披露文字（审核备注）

> eSheep+ does not contain ads or cross-app tracking. Cloud account and farm data are processed by the configured Supabase project. Optional AI requests are sent directly from the user's device to Xiaomi MiMo with a user-supplied API key; text, selected processed images, audio, and limited authorized farm results may be included. AI is separately consented to, remains optional, and cannot directly execute a farm write. Sent-audio retention is off by default.

## 五、提交前证据门禁

- [ ] 正式主体、域名和隐私邮箱已替换，公开政策可稳定访问。
- [ ] Production Supabase 区域、DPA、子处理者和日志/备份期限已确认。
- [ ] SMTP 服务商、地域、DPA 和日志期限已确认。
- [ ] MiMo 当期隐私政策、处理地域、训练与保存承诺已复核并截图归档。
- [ ] Release Archive 的 Xcode 聚合隐私报告与本表逐项一致。
- [ ] `PrivacyInfo.xcprivacy` 包含 Name、Email、Physical Address、Precise Location、Photos/Videos、Audio、Other User Content、User ID、Device ID、Other Usage Data、Other Diagnostic Data。
- [ ] 真机验证所有系统权限按需触发，拒绝后无关核心功能可用。
- [ ] App Store Connect 保存最终回答截图/PDF，并与 commit、构建号和政策版本绑定。

