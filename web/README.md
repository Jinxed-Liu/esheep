# eSheepNext Web

eSheepNext 的网页工作台，采用 React、Vite 与 Supabase 浏览器客户端构建。界面依据 `design-reference.png` 的「Daily Field Ledger」方案实现，并保留原生 App 的生产事实、历史台账、权限与同步边界。

## 已实现工作区

- 首页：待办与异常、最近事件、牧场指标、快捷录入、当日 TMR 执行。
- 羊群：羊只与圈舍切换、筛选、表格和生产记录入口。
- 录入：建档、称重、转群、离场、健康、繁殖与投喂动作。
- 投喂：投喂历史、原料库、配方，以及受控的 `早 / 中 / 晚 / 全天` 顿次。
- TMR：当日计划、配方/生产与偏差监控。
- 洞察：核心指标、趋势与可解释异常规则。
- Codex 牧场助手：服务端 Codex harness 线程、MiMo 双模型、App 同口径只读查询与图片理解。
- 事件记录：可筛选审计台账。
- 设置：Supabase 邮箱密码 / Apple 登录、云端状态、角色能力与写入安全边界。

## Supabase 边界

浏览器仅使用 publishable key。登录后通过现有 RLS、成员关系和牧场范围读取 `farm_entities` 与 `farm_operations`，并调用成员牧场 RPC。当前真实读取范围是牧场、羊只、圈舍、投喂、称重、转群、离场、原料、TMR 配方/计划与事件；读取会分页，并同时解析 `payload_json` 与 compact projection 的 `payload_base64`。在场羊只按原生有效状态和历史归档规则过滤；单独存在的历史离场事件不会覆盖有效的权威状态快照。若紧凑投影的最新行只是护理/资料增量，网页会保留数量但标记字段“资料未展开”，不猜填旧值。规则告警、库存、TMR 顿次完成/偏差监控和趋势洞察尚未接入，界面会显示空状态或“未接入”，不会伪造数值。

Apple 登录使用 Supabase Auth 的 OAuth 重定向流程，回调地址为当前网页根路径。Supabase 项目的 Apple Provider 需要在 Auth 设置中保持启用，并在 Apple Developer 与 Supabase 中配置 Services ID、回调地址和密钥；这些敏感配置不进入网页端代码。

生产写入目前有意保持为浏览器草稿。只有在网页端完整承接 App 的命令校验、设备身份、修订冲突、审计事件、Outbox 与远端重放后，才应连接真实写入；界面不会把草稿描述为「已提交」。

## Codex harness 与 MiMo

网页 AI 助手不再使用浏览器里的固定回复。每个账号与牧场获得独立的服务端 Codex 线程：纯文字和确定性牧场查询固定使用 `mimo-v2.5-pro`，用户主动附加 JPEG、PNG 或 WebP 图片时，同一线程本轮自动使用 `mimo-v2.5`。Codex 运行目录为只读沙箱，禁用网络、Web 搜索和审批式命令，只能调用随会话生成的 `query-farm.mjs`，该工具复用网页与 App 对齐的体重、产羔、繁殖和采食统计语义。

浏览器继续只持有 Supabase publishable key。每次助手请求都会把当前访问令牌发给服务端；服务端使用 Supabase `getUser` 验证令牌，并重新调用 `list_my_active_farm_access` 核对牧场成员关系。

MiMo 采用严格的 BYOK（Bring Your Own Key）：服务端不配置、不共享 `MIMO_API_KEY`。每个已登录账号在一台浏览器上首次进入助手时填写自己的 `sk-` 或 `tp-` Key；网页使用 Web Crypto 的不可导出 AES-GCM 密钥加密后保存在同源 IndexedDB，再次打开时自动恢复。若浏览器禁用了私密存储，则降级为仅当前页面内存有效并明确提示。Key 不写入 localStorage、牧场快照、Codex 会话元数据或流式响应，只在发起助手请求时通过专用请求头交给服务端，并仅注入本轮 Codex 子进程环境。用户可随时更换或移除本机保存的 Key。

localStorage 只保存一个按账号/牧场分区的随机会话 ID；服务端会话、所选图片和 Codex 状态默认 12 小时后清理，也可在界面点击“新会话”立即删除。

Codex SDK 需要 Node.js 进程和本地可执行环境，不能直接运行在只提供静态资源的 Sites Worker 中。`worker/index.js` 会把 `/api/assistant/*` 转发给 `CODEX_HARNESS` 服务绑定或 HTTPS `CODEX_HARNESS_URL`；未绑定时明确返回 503，不会退回伪造答案。

## 本地配置

将 `.env.example` 复制为 `.env.local`，填入：

```dotenv
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_your_key
```

常用命令：

```bash
npm install
npm run dev
npm run build
npm run test:sites
```

`npm run dev` 会在同一个本地端口启动 Vite 与 Codex harness API；`npm run preview`/`npm start` 会从 `dist/client` 提供构建产物并启动相同的 API。登录云端牧场后，在 Codex 牧场助手界面首次填写自己的 MiMo Key；以后同一账号、同一浏览器会自动使用。`tp-` 开头的 Token Plan Key 自动使用 `https://token-plan-cn.xiaomimimo.com/v1`，`sk-` Key 使用 Pay-as-you-go 地址。正式部署前还需在服务端运行环境配置 Supabase URL/publishable key、私有可写会话目录和 HTTPS 反向代理；HTTPS 也是浏览器 Web Crypto 持久化凭据的生产前提。

设计与验收说明见 `DESIGN_SPEC.md` 和 `design-qa.md`。
