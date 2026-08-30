import SwiftUI

private struct LegalSection: Identifiable {
    let heading: String
    let paragraphs: [String]
    let bullets: [String]

    var id: String { heading }

    init(_ heading: String, paragraphs: [String] = [], bullets: [String] = []) {
        self.heading = heading
        self.paragraphs = paragraphs
        self.bullets = bullets
    }
}

enum LegalDocument: String, CaseIterable, Identifiable {
    case terms
    case privacy
    case crossBorder
    case ai
    case permissions

    var id: String { rawValue }

    var title: String {
        return switch self {
        case .terms: "服务条款"
        case .privacy: "隐私政策"
        case .crossBorder: "境外提供个人信息告知"
        case .ai: "AI 数据处理说明"
        case .permissions: "个人信息与权限清单"
        }
    }

    var systemImage: String {
        switch self {
        case .terms: "doc.text"
        case .privacy: "hand.raised"
        case .crossBorder: "globe.asia.australia"
        case .ai: "sparkles"
        case .permissions: "checklist"
        }
    }

    fileprivate func localizedTitle(isChinese: Bool) -> String {
        guard !isChinese else { return title }
        return switch self {
        case .terms: "Terms of Service"
        case .privacy: "Privacy Policy"
        case .crossBorder: "International Transfer Notice"
        case .ai: "AI Data Notice"
        case .permissions: "Data and Permissions List"
        }
    }

    fileprivate func sections(isChinese: Bool) -> [LegalSection] {
        isChinese ? chineseSections : englishSections
    }

    private var chineseSections: [LegalSection] {
        switch self {
        case .terms:
            return [
                LegalSection("1. 签约主体和接受条款", paragraphs: [
                    "本条款是用户与 {{LEGAL_ENTITY}}（“我们”）之间关于下载、注册和使用 eSheep+ 的协议。用户应在登录或注册前完整阅读；主动勾选并继续表示明确接受。不同意时请勿创建账号或使用云端服务。",
                ]),
                LegalSection("2. 用户资格", paragraphs: [
                    "用户应具有完全民事行为能力，并有权代表其牧场、单位或组织处理和共享相关数据。本服务不面向不满十四周岁的未成年人。",
                ]),
                LegalSection("3. 服务内容", paragraphs: [
                    "eSheep+ 提供羊只、圈舍、称重、健康、繁殖、饲喂、配方、TMR、库存、提醒等记录与分析，本机离线使用、导入导出、eSheep 云同步、成员协作、本地牧场迁移及可选 AI 助手。具体功能以当前版本和账号权限为准。",
                    "设备、网络和第三方服务状态会影响部分功能。App 会尽力保留待同步状态，但用户仍应核对关键记录并定期导出备份。",
                ]),
                LegalSection("4. 账户和安全", paragraphs: [
                    "用户应提供真实可用的邮箱或合法 Apple 账户，妥善保管密码、设备、邮箱、恢复码和自行配置的 API Key，不得转让、出租或共享凭据。发现未经授权访问、设备遗失或密钥泄露时应立即撤销并联系 {{PRIVACY_EMAIL}}。",
                    "牧场主和管理员应遵循最小权限原则邀请、变更和撤销成员。",
                ]),
                LegalSection("5. 用户内容与权利", paragraphs: [
                    "用户及其合法权利人保留对所录入牧场数据、文字、图片和文件的合法权利。用户仅授予我们为提供、保护、同步、恢复和导出其请求的功能所必要的处理许可；该许可不允许出售内容或用于第三方广告。",
                    "用户保证有权录入、上传和共享内容，不侵犯他人的个人信息、著作权、商业秘密或其他权利。",
                ]),
                LegalSection("6. 禁止行为", bullets: [
                    "违法收集、监控、公开、出售或滥用个人信息；",
                    "上传恶意代码、攻击服务、绕过角色权限或读取他人牧场；",
                    "冒用身份、伪造记录、侵犯知识产权或传播违法内容；",
                    "用 AI 对自然人作出未经人工复核且对其权益有重大影响的决定；",
                    "未经授权转售、批量抓取或破坏性逆向服务。",
                ]),
                LegalSection("7. AI 和专业判断", paragraphs: [
                    "AI 助手使用用户自有 MiMo API Key，是可选辅助功能。模型可能不准确、不完整或过时，只能生成分析或待确认草案；所有关键操作必须由具备权限的用户核对确认。",
                    "养殖、营养、健康、天气和成本分析不替代执业兽医、实验室检测、药品说明、法律法规、会计意见或现场安全判断。",
                ]),
                LegalSection("8. 隐私、跨境和费用", paragraphs: [
                    "个人信息处理遵循本 App 的隐私政策及 AI/境外提供专项告知。eSheep+ 3.1 首发版本免费，无 App 内购买或自动续期订阅；设备、网络及用户直接向 MiMo 等第三方支付的费用由用户承担。未来付费功能会在购买前另行明确，不会仅凭本条款收费。",
                ]),
                LegalSection("9. 变更、暂停和终止", paragraphs: [
                    "我们可能为安全、合规或维护更新服务。用户可停止使用并注销；牧场主注销前应先导出并转移或删除自有牧场。违法、攻击、严重越权或危害他人时，我们可在必要范围内暂停服务并依法提供说明和申诉路径。",
                ]),
                LegalSection("10. 可用性和责任边界", paragraphs: [
                    "我们采取合理措施保护数据和维持服务，但不承诺设备、网络、第三方平台、天气或 AI 永不中断、绝对准确或绝对安全。本条不排除因故意、重大过失、侵害人身权益、违反个人信息保护义务或法律不得排除的责任。",
                ]),
                LegalSection("11. 法律和争议", paragraphs: [
                    "本条款适用中华人民共和国大陆地区法律。争议可先通过 {{PRIVACY_EMAIL}} 协商；协商不成，依法向有管辖权的人民法院提起诉讼。本条不影响依法投诉或主张法定权利。",
                ]),
            ]

        case .privacy:
            return [
                LegalSection("个人信息处理者", paragraphs: [
                    "处理者：{{LEGAL_ENTITY}}；注册地址：{{REGISTERED_ADDRESS}}；个人信息保护联系人：{{PRIVACY_OWNER}}；邮箱：{{PRIVACY_EMAIL}}。这些占位符必须在正式发布前替换，否则本文仅为预发布草案。",
                    "本政策适用于 eSheep+。羊只生产数据通常不是自然人医疗信息；若其中含姓名、电话、语音、影像或其他可识别自然人的内容，仍按个人信息保护。",
                ]),
                LegalSection("1. 账户、设备和安全信息", paragraphs: [
                    "我们处理显示名、邮箱、Apple 登录稳定标识、eSheep 账号 ID、App 生成的设备 UUID、设备名、公钥、协议版本和会话状态，用于注册、验证、登录、成员识别、设备撤权、同步兼容和安全。密码由认证服务验证；Face ID/Touch ID 模板由 Apple 在设备内处理，eSheep+ 不取得模板。",
                ]),
                LegalSection("2. 牧场内容、附件和位置", paragraphs: [
                    "用户主动录入的牧场名称/地址、坐标、时区、成员角色、羊只、圈舍、称重、繁殖、健康、防疫、药品、饲喂、配方、TMR、库存、成本、提醒、备注、照片、附件和操作历史，用于记录、计算、导出、同步、恢复及按角色协作。",
                    "位置只在用户主动保存牧场地点或使用相关天气功能时申请，不做后台人员轨迹或广告画像。只处理用户拍摄或选择的照片/文件，不扫描整个相册。AI 图片会先缩放、重新编码并移除原始 EXIF/位置元数据。",
                ]),
                LegalSection("3. 可选 AI 和服务日志", paragraphs: [
                    "另行同意并主动发送后，App 才向 MiMo 提交问题、选定图片、语音、会话上下文和为当前问题授权查询的有限牧场结果。MiMo API Key 保存在本机钥匙串，由设备直接鉴权。",
                    "认证、同步、数据库、对象存储、邮件和删除任务可能产生时间、请求状态、错误码、IP、用户/设备标识及必要安全日志，用于安全、诊断、恢复和审计；普通日志不得包含密码、完整令牌或 API Key。",
                ]),
                LegalSection("4. 处理目的和合法性基础", bullets: [
                    "履行条款：账号、离线记录、同步、协作、导入导出、恢复和客服；",
                    "取得同意后：位置、相机、麦克风、照片、日历/提醒、通知、AI 和依法需要同意的境外提供；",
                    "履行法定义务、保护账号和数据，或在法律允许的紧急情况下保护生命健康和财产安全。",
                    "目的、方式或信息种类实质变化时更新政策，并在法律要求时重新取得同意。",
                ]),
                LegalSection("5. 本机处理", paragraphs: [
                    "离线记录、本机导入、Keychain 凭据、AI 会话和可选语音副本可仅在当前设备处理。默认不长期保留已发送语音；用户可主动开启，关闭只影响之后发送的语音。",
                ]),
                LegalSection("6. 委托处理、共享和对外提供", paragraphs: [
                    "我们不出售个人信息、不投放第三方广告、不使用广告标识符，也不跨 App/网站跟踪。服务商包括 Supabase 及其基础设施子处理者（认证、数据库、存储、实时提示、备份和日志）、{{SMTP_PROVIDER}}（认证邮件）和 Apple（登录、系统通知、地图/天气及权限）。",
                    "受邀成员只可在角色允许范围处理当前牧场。除用户主动操作、履行合同所需、依法提供或紧急保护外，不向其他处理者提供个人信息；法律要求时先做影响评估并取得单独同意。",
                ]),
                LegalSection("7. 境外提供", paragraphs: [
                    "账号、同步和可选 AI 可能涉及中国大陆以外处理。接收方、国家/地区、目的、方式、种类和权利渠道见独立境外告知；核心云和 AI 分别同意。用户可以撤回，撤回不影响此前处理，但会停止新的对应传输并可能导致云或 AI 功能不可用。",
                ]),
                LegalSection("8. 保存与删除", bullets: [
                    "本机数据：用户保留相应牧场/会话/账号期间，用户删除或卸载时清理；",
                    "账号、成员和设备：服务存续期间；注销后撤销并进入删除任务；",
                    "云端牧场：牧场存续及保障账目、审计和协作所需期间；必要的不可变历史去标识化；",
                    "无所有权阻塞后，账户主动库清理目标 24 小时；备份和安全日志目标最长 30 日，法律或事件调查另有要求除外；",
                    "影响评估和法定记录按法律期限保存，影响评估记录至少三年。",
                ]),
                LegalSection("9. 安全", paragraphs: [
                    "措施包括 TLS、iOS Keychain、设备密钥、Supabase RLS/受控 RPC、私有存储、角色权限、会话撤销、图片去元数据、日志最小化、备份和恢复检查。发生或可能发生泄露、篡改、丢失时会立即补救，并依法通知保护部门和受影响个人。",
                ]),
                LegalSection("10. 个人权利", paragraphs: [
                    "用户可查阅、复制、解释、更正、补充、删除、限制、依法转移、撤回同意、退出共享牧场、注销和投诉。通过 App 或 {{PRIVACY_EMAIL}} 提交；我们进行最小身份/权限核验，通常以 15 个工作日为内部目标，拒绝时说明理由。牧场主注销前需先转移或删除自有牧场。",
                ]),
                LegalSection("11. 未成年人和政策变更", paragraphs: [
                    "服务不面向不满十四周岁未成年人。发现未经监护人同意处理时会暂停、联系监护人并依法删除。重大政策变化会显著告知，并在法律要求时重新取得同意；历史版本和同意证据按合规需要保存。",
                ]),
            ]

        case .crossBorder:
            return [
                LegalSection("核心云接收方", paragraphs: [
                    "接收方为 Supabase, Inc./Supabase Pte. Ltd. 及 DPA 所列基础设施子处理者；生产区域为 {{SUPABASE_REGION_COUNTRY}}（计划新加坡，正式发布前按控制台和合同确认）。可先通过 {{PRIVACY_EMAIL}} 行使权利，也可使用 Supabase 官方隐私渠道。",
                ]),
                LegalSection("目的、方式和数据种类", paragraphs: [
                    "目的为账号认证、数据库同步、私有附件、角色协作、恢复、备份和安全审计。App 通过加密连接直达生产项目，以账号/牧场/角色 RLS 和受控 RPC 处理显示名、邮箱、用户/设备标识、会话安全、牧场位置、成员关系、生产内容、附件以及必要 IP/时间/状态/安全日志。",
                ]),
                LegalSection("邮件服务", paragraphs: [
                    "认证邮件接收方为 {{SMTP_PROVIDER}}，地域 {{SMTP_REGION_COUNTRY}}，处理邮箱、邮件内容、投递状态和必要日志。上述主体、地域、权利渠道及期限未补全前不得正式上线邮箱注册。",
                ]),
                LegalSection("必要性、保存和撤回", paragraphs: [
                    "当前账号、云同步和协作依赖境外基础设施。拒绝或撤回后停止新的对应传输，云功能将无法继续；依法可用的导出、注销和本地处理路径不因此被剥夺。活跃数据按服务期保存；删除任务和最长 30 日备份/日志目标以正式生产配置为准。",
                ]),
                LegalSection("风险与保护", paragraphs: [
                    "境外法域的数据保护和政府访问规则可能不同，也存在故障、未授权访问和子处理者变化风险。我们采用 DPA/合同复核、TLS、Keychain、RLS、私有存储、最小权限、删除和事件预案；并按适用法律评估安全评估、认证、标准合同备案或其他条件。",
                ]),
                LegalSection("单独同意", paragraphs: [
                    "登录页对本告知单独、默认不勾选。勾选仅表示同意核心云处理，不替代可选 MiMo AI 的另行同意。撤回不影响撤回前基于同意的处理效力。",
                ]),
            ]

        case .ai:
            return [
                LegalSection("可选功能与接收方", paragraphs: [
                    "AI 助手完全可选。MiMo 2026-07-07 服务协议称平台由 Xiaomi Technologies Singapore Pte. Ltd. 运营，并同时列明荷兰主体及适用关联公司；实际 API 地域为 {{MIMO_API_REGION_COUNTRY}}，须在发布前书面核实。拒绝 AI 不影响非 AI 的牧场记录、同步和导出。",
                ]),
                LegalSection("发送方式和内容", paragraphs: [
                    "用户提供自己的 MiMo API Key，iPhone 通过加密连接直接调用 MiMo；eSheep 服务端不接触明文 Key。发送内容仅限主动文字、经去 EXIF 的选定图片、主动录音、相关会话上下文和为当前问题授权的有限牧场结果。扩展敏感明细会逐次提示。",
                ]),
                LegalSection("不会主动发送", bullets: [
                    "密码、验证码、Apple 或 Supabase 登录令牌；",
                    "MiMo API Key 本身；",
                    "未被选择的相册内容或导入文件原件；",
                    "与当前问题无关的完整牧场数据。",
                ]),
                LegalSection("保存、训练和撤回", paragraphs: [
                    "会话默认保存在本机；已发送语音的长期本机保留默认关闭。MiMo 的保存和删除按其当期 API 规则执行。其隐私政策版本 v20260421（页面声明 2026-03-17 更新）称 API 内容不用于模型训练或其他目的，我们会定期复核。",
                    "用户可撤回同意；撤回后停止新请求，并可删除本机 Key 和历史会话。",
                ]),
                LegalSection("人工控制和风险", paragraphs: [
                    "模型可能出错。AI 不能直接写入牧场，只生成待确认草案，必须由有权限用户核对。请勿提交密码、证件号、银行卡、自然人医疗记录或无关个人信息；AI 不是兽医、法律或财务意见。",
                ]),
            ]

        case .permissions:
            return [
                LegalSection("系统权限原则", paragraphs: [
                    "权限只在相应功能首次需要时由 iOS 请求。拒绝不会影响无关功能；可在系统设置随时关闭。eSheep+ 不投放广告、不申请 ATT、不读取系统通讯录。",
                ]),
                LegalSection("相机和照片", paragraphs: [
                    "相机用于拍摄羊只、病症、耳标、票据和二维码。照片选择器只提供用户主动选中的照片/视频，不扫描完整相册。内容可按用户选择保存在本机、上传私有云附件或发送 AI。",
                ]),
                LegalSection("麦克风", paragraphs: [
                    "只在用户按下录音并发送 AI 问题时采集语音。发送至 MiMo 前明确显示；长期本机保留默认关闭。",
                ]),
                LegalSection("位置、地图和天气", paragraphs: [
                    "仅申请“使用 App 期间”位置，用于用户主动保存牧场坐标、时区和对应天气。无后台持续定位，不用于广告或人员考勤轨迹。",
                ]),
                LegalSection("日历、提醒和通知", paragraphs: [
                    "只有用户确认后才把事项写入系统日历/提醒；系统数据库由 Apple 管理。通知用于用户创建的生产提醒、同步或安全状态。App 不持久保存 APNs 令牌，只记录必要的注册状态/错误。",
                ]),
                LegalSection("附近设备、本地网络和 Face ID", paragraphs: [
                    "附近交互和本地网络用于用户主动使用的近距设备功能，距离在本机处理。Face ID/Touch ID 用于保护导出、密钥、敏感操作和账户删除；生物识别模板不离开 Apple 安全系统。",
                ]),
            ]
        }
    }

    private var englishSections: [LegalSection] {
        // English is complete but intentionally condensed for the in-app
        // layered notice. The public English policy carries the same scope in
        // full detail and is linked from the App Store listing.
        switch self {
        case .terms:
            return [
                LegalSection("1. Parties and acceptance", paragraphs: ["These Terms are between the user and {{LEGAL_ENTITY}}. Explicit acceptance is required before an account or cloud service is used."]),
                LegalSection("2. Eligibility", paragraphs: ["Users must have full legal capacity and authority for the farm or organization. The service is not directed to children under 14."]),
                LegalSection("3. Service", paragraphs: ["eSheep+ provides offline farm records, analysis, imports/exports, cloud sync, collaboration, legacy migration, and optional AI. Device, network, Apple, Supabase, email, and MiMo availability can affect features. Review critical records and export backups."]),
                LegalSection("4. Accounts and access", paragraphs: ["Protect passwords, devices, mailboxes, recovery codes, and API keys. Owners and administrators must use minimum member permissions and promptly revoke obsolete access. Report compromise to {{PRIVACY_EMAIL}}."]),
                LegalSection("5. User content", paragraphs: ["Users retain lawful rights in their content and license us only to provide, secure, sync, recover, and export requested features. Users must have authority to upload and share content and must respect privacy, copyright, and trade-secret rights."]),
                LegalSection("6. Prohibited use", bullets: ["Unlawful surveillance or sale of personal data;", "Malware, attacks, access-control bypass, or another farm's data;", "Impersonation, falsified records, or infringement;", "Unreviewed AI decisions materially affecting a person;", "Unauthorized resale, scraping, or destructive reverse engineering."]),
                LegalSection("7. AI and professional judgment", paragraphs: ["Optional AI uses a user-supplied MiMo key, can be wrong, and creates only reviewable drafts. An authorized person must confirm every consequential action. Farm analysis is not veterinary, legal, accounting, or emergency advice."]),
                LegalSection("8. Privacy and fees", paragraphs: ["The Privacy Policy and AI/Transfer Notice govern personal information. Version 3.1 is free with no IAP or auto-renewing subscription. Users pay direct third-party charges; future paid features require a separate pre-purchase disclosure."]),
                LegalSection("9. Changes and termination", paragraphs: ["We may update the service for security, compliance, or maintenance. Users may close an account after exporting and transferring or deleting owned farms. Serious unlawful or harmful activity may be narrowly suspended with an explanation where permitted."]),
                LegalSection("10. Availability, law, and disputes", paragraphs: ["Reasonable safeguards do not guarantee uninterrupted or error-free devices, networks, providers, weather, or AI. Mandatory liability is not excluded. Mainland Chinese law applies; contact {{PRIVACY_EMAIL}} before litigation in a court with lawful jurisdiction."]),
            ]
        case .privacy:
            return [
                LegalSection("Controller", paragraphs: ["Controller: {{LEGAL_ENTITY}}; address: {{REGISTERED_ADDRESS}}; privacy owner: {{PRIVACY_OWNER}}; email: {{PRIVACY_EMAIL}}. Placeholders must be replaced before release."]),
                LegalSection("1. Account and device data", paragraphs: ["We process display name, email, Apple/eSheep IDs, app-generated device UUID, public key, protocol version, and session status for authentication, membership, revocation, compatibility, and security. We do not receive readable passwords or Apple biometric templates."]),
                LegalSection("2. Farm content, media, and location", paragraphs: ["Intentional farm, member, animal, health, feed, TMR, stock, cost, note, attachment, and operation data supports records, calculations, export, sync, recovery, and role access. Location is only for an intentional farm coordinate/time zone/weather request. Selected AI images are re-encoded without original EXIF."]),
                LegalSection("3. Optional AI and service records", paragraphs: ["After separate consent, intentional prompts, selected images/audio, context, and limited farm results go directly to MiMo using a local Keychain API key. Auth, sync, storage, email, and deletion may retain limited time, status, error, IP, user/device, and security logs; no passwords, full tokens, or API keys belong in ordinary logs."]),
                LegalSection("4. Purpose and on-device boundary", paragraphs: ["We process data to perform the Terms, provide consented permissions and overseas/AI features, comply with law, and protect accounts. Material changes receive an updated notice and renewed consent where required. Offline records, imports, credentials, and conversations can remain only on-device; sent-audio retention is off by default."]),
                LegalSection("5. Processors and sharing", paragraphs: ["We do not sell data, show third-party ads, use IDFA, or track across apps/websites. Processors include Supabase and infrastructure subprocessors, {{SMTP_PROVIDER}}, and Apple. Invited farm members see only role-authorized data. Other-controller disclosure occurs only when initiated, necessary, lawful, or emergency-based, with impact assessment and separate consent where required."]),
                LegalSection("6. International transfers", paragraphs: ["Accounts/sync and optional AI may process data outside Mainland China. The separate notice identifies recipients, regions, purposes, categories, retention, risks, and rights. Core cloud and AI consents are separate. Withdrawal stops new relevant transfers and may disable the dependent feature."]),
                LegalSection("7. Retention and deletion", paragraphs: ["Data is kept for the shortest necessary service period. Active deletion targets 24 hours after ownership blockers clear. Immutable shared-ledger operations may be de-identified. Backup/security-log target maximum is 30 days unless law or an active incident requires longer. Impact-assessment records remain at least three years."]),
                LegalSection("8. Security and rights", paragraphs: ["Safeguards include TLS, Keychain, device keys, RLS/RPC, private storage, role access, revocation, metadata removal, minimized logs, backups, and incident response. Users may access, copy, explain, correct, delete, restrict, transfer where eligible, withdraw, leave a farm, close an account, or complain through the app or {{PRIVACY_EMAIL}}; the internal response target is 15 business days."]),
                LegalSection("9. Children and changes", paragraphs: ["The service is not directed to children under 14. Invalid child processing will be suspended and deleted as required. Material policy changes receive prominent notice and renewed consent where required."]),
            ]
        case .crossBorder:
            return [
                LegalSection("Core recipient", paragraphs: ["Supabase, Inc./Supabase Pte. Ltd. and DPA subprocessors process accounts, sync, private attachments, collaboration, recovery, backup, and security in {{SUPABASE_REGION_COUNTRY}} (planned Singapore; verify before release). Rights may be requested through {{PRIVACY_EMAIL}} or Supabase's official privacy channel."]),
                LegalSection("Data and method", paragraphs: ["Encrypted connections and account/farm/role RLS/RPC protect name, email, IDs, session security, farm location, memberships, farm content/attachments, and necessary IP/time/status/security logs."]),
                LegalSection("Email", paragraphs: ["{{SMTP_PROVIDER}} in {{SMTP_REGION_COUNTRY}} processes email, message content, delivery status, and necessary logs. Email registration must not launch until identity, location, rights channel, and retention are completed."]),
                LegalSection("Necessity, risks, and withdrawal", paragraphs: ["Core cloud functions depend on overseas infrastructure. Refusal or withdrawal stops future transfers and disables those features while preserving available export, closure, and local options. Different laws, government access, outages, unauthorized access, and subprocessor changes are mitigated by contracts, TLS, Keychain, RLS, private storage, deletion, and incident response."]),
                LegalSection("Separate consent", paragraphs: ["This consent is unchecked by default and covers core cloud processing only. Optional MiMo AI requires another consent. Withdrawal does not invalidate prior lawful processing."]),
            ]
        case .ai:
            return [
                LegalSection("Optional recipient", paragraphs: ["Xiaomi MiMo is optional. Its July 7, 2026 Service Agreement identifies Xiaomi Technologies Singapore Pte. Ltd. as operator and also lists a Netherlands entity and applicable affiliates. The actual API region is {{MIMO_API_REGION_COUNTRY}} and requires written verification before release. Refusal does not affect non-AI records, sync, or export."]),
                LegalSection("Content and transport", paragraphs: ["A user-supplied key stays in local Keychain while the iPhone sends intentional text, EXIF-stripped selected images, recordings, relevant context, and limited authorized farm results directly to MiMo over encryption. Broader detail receives a per-action prompt."]),
                LegalSection("Excluded data", bullets: ["Passwords, codes, Apple/Supabase tokens, or the MiMo key;", "Unselected photo-library or original import content;", "Unrelated full-farm data."]),
                LegalSection("Retention, control, and risk", paragraphs: ["Conversations remain local and sent-audio retention is off by default. MiMo Privacy Policy version v20260421 (stated update date: March 17, 2026) says submitted API content is not used for training or other purposes; we recheck changes. AI can be wrong and cannot execute writes directly. Withdraw to stop new requests and remove the local key/history."]),
            ]
        case .permissions:
            return [
                LegalSection("Permission principle", paragraphs: ["iOS requests a permission only when its feature needs it. Refusal does not disable unrelated features. There is no ATT request or Contacts access."]),
                LegalSection("Camera, selected photos, and microphone", paragraphs: ["Camera and selected photos attach intentional farm media or scans. The app does not scan the library. Microphone records only an intentional AI prompt; long-term sent-audio retention is off by default."]),
                LegalSection("Location, calendar, reminders, notifications", paragraphs: ["While-in-use location saves a farm coordinate/time zone and related weather, never background staff tracking. Calendar/reminder writes occur only after confirmation. Notifications carry user-created farm or security reminders; only necessary registration status/errors are retained."]),
                LegalSection("Nearby, local network, and biometrics", paragraphs: ["Intentional nearby/local-network features process distance locally. Face ID/Touch ID protects exports, keys, sensitive actions, and deletion; eSheep+ never receives the biometric template."]),
            ]
        }
    }
}

struct LegalDocumentView: View {
    @Environment(\.locale) private var locale

    let document: LegalDocument

    private var isChinese: Bool {
        locale.language.languageCode?.identifier == "zh"
    }

    var body: some View {
        List {
            Section {
                LabeledContent(isChinese ? "版本" : "Version", value: version)
                LabeledContent(
                    isChinese ? "更新 / 生效" : "Updated / effective",
                    value: "\(LegalPolicyVersions.updatedAt) / \(LegalPolicyVersions.effectiveAt)"
                )
                if document == .terms || document == .privacy {
                    Text(isChinese
                         ? "正式发布前必须将主体、地址、隐私负责人和邮箱占位符替换为真实信息。"
                         : "Controller, address, privacy owner, and email placeholders must be replaced before release.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(document.sections(isChinese: isChinese)) { section in
                Section {
                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(verbatim: paragraph)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                        Label {
                            Text(verbatim: bullet)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text(verbatim: section.heading)
                }
            }
        }
        .navigationTitle(document.localizedTitle(isChinese: isChinese))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        switch document {
        case .terms: LegalPolicyVersions.terms
        case .privacy, .permissions: LegalPolicyVersions.privacy
        case .crossBorder: LegalPolicyVersions.crossBorder
        case .ai: LegalPolicyVersions.ai
        }
    }
}
