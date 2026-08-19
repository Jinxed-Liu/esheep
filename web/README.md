# eSheepNext Web

eSheepNext 的网页工作台，采用 React、Vite 与 Supabase 浏览器客户端构建。界面依据 `design-reference.png` 的「Daily Field Ledger」方案实现，并保留原生 App 的生产事实、历史台账、权限与同步边界。

## 已实现工作区

- 首页：待办与异常、最近事件、牧场指标、快捷录入、当日 TMR 执行。
- 羊群：羊只与圈舍切换、筛选、表格和生产记录入口。
- 录入：建档、称重、转群、离场、健康、繁殖与投喂动作。
- 投喂：投喂历史、原料库、配方，以及受控的 `早 / 中 / 晚 / 全天` 顿次。
- TMR：当日计划、配方/生产与偏差监控。
- 洞察：核心指标、趋势与可解释异常规则。
- 事件记录：可筛选审计台账。
- 设置：Supabase 邮箱密码 / Apple 登录、云端状态、角色能力与写入安全边界。

## Supabase 边界

浏览器仅使用 publishable key。登录后通过现有 RLS、成员关系和牧场范围读取 `farm_entities` 与 `farm_operations`，并调用成员牧场 RPC。当前真实读取范围是牧场、羊只、圈舍、投喂、称重、转群、离场、原料、TMR 配方/计划与事件；读取会分页，并同时解析 `payload_json` 与 compact projection 的 `payload_base64`。在场羊只按原生有效状态和历史归档规则过滤；单独存在的历史离场事件不会覆盖有效的权威状态快照。若紧凑投影的最新行只是护理/资料增量，网页会保留数量但标记字段“资料未展开”，不猜填旧值。规则告警、库存、TMR 顿次完成/偏差监控和趋势洞察尚未接入，界面会显示空状态或“未接入”，不会伪造数值。

Apple 登录使用 Supabase Auth 的 OAuth 重定向流程，回调地址为当前网页根路径。Supabase 项目的 Apple Provider 需要在 Auth 设置中保持启用，并在 Apple Developer 与 Supabase 中配置 Services ID、回调地址和密钥；这些敏感配置不进入网页端代码。

生产写入目前有意保持为浏览器草稿。只有在网页端完整承接 App 的命令校验、设备身份、修订冲突、审计事件、Outbox 与远端重放后，才应连接真实写入；界面不会把草稿描述为「已提交」。

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

设计与验收说明见 `DESIGN_SPEC.md` 和 `design-qa.md`。
