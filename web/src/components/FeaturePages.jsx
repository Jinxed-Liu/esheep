import { useMemo, useState } from "react";
import {
  Pulse as Activity,
  AppleLogo,
  ArrowsLeftRight,
  Baby,
  Barn,
  BowlFood,
  ChartLineUp,
  CheckCircle,
  CloudArrowDown,
  CloudCheck,
  CloudSlash,
  FirstAid,
  ForkKnife,
  Gear,
  Heart,
  LockKey,
  MagnifyingGlass,
  Package,
  Plus,
  ShieldCheck,
  SignIn,
  SignOut,
  Syringe,
  UsersThree,
  WarningCircle,
} from "@phosphor-icons/react";
import { demoInsightSeries } from "../data/demoData.js";
import { SheepGlyph as Sheep, WeightGlyph as Scale } from "./DomainIcons.jsx";

function PageTop({ title, description, actionLabel, onAction, icon: Icon = Plus }) {
  return (
    <header className="feature-page-top">
      <span>
        <h1>{title}</h1>
        <p>{description}</p>
      </span>
      {actionLabel ? (
        <button className="primary-button" type="button" onClick={onAction}>
          <Icon size={20} />
          {actionLabel}
        </button>
      ) : null}
    </header>
  );
}

function Segmented({ items, value, onChange }) {
  return (
    <div className="segmented" role="tablist">
      {items.map((item) => (
        <button
          type="button"
          role="tab"
          aria-selected={value === item.id}
          className={value === item.id ? "active" : ""}
          key={item.id}
          onClick={() => onChange(item.id)}
        >
          {item.label}
        </button>
      ))}
    </div>
  );
}

function ProjectionNotice({ children }) {
  return <div className="projection-notice"><WarningCircle size={19} weight="fill" /><span>{children}</span></div>;
}

function formatDateTime(value, timeZone = "Asia/Shanghai") {
  if (!value) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone,
  }).format(new Date(value));
}

export function FlockPage({ workspace, onCreateRecord }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const baseline = workspace.projectionCoverage?.baseline;
  const [view, setView] = useState("sheep");
  const [filter, setFilter] = useState("");
  const lowerFilter = filter.trim().toLowerCase();
  const sheepRows = useMemo(
    () => workspace.sheep.filter((sheep) =>
      [sheep.earTag, sheep.breed, sheep.pen, sheep.stage].some((value) =>
        String(value ?? "").toLowerCase().includes(lowerFilter),
      ),
    ),
    [lowerFilter, workspace.sheep],
  );
  const penRows = useMemo(
    () => workspace.pens.filter((pen) => pen.headCount > 0).filter((pen) =>
      [pen.name, pen.purpose, pen.status].some((value) =>
        String(value ?? "").toLowerCase().includes(lowerFilter),
      ),
    ),
    [lowerFilter, workspace.pens],
  );

  return (
    <main className="page feature-page">
      <PageTop
        title="羊群"
        description="按有效历史查看羊只、圈舍与当前生产状态。"
        actionLabel="新建羊只"
        onAction={() => onCreateRecord("addSheep")}
        icon={Sheep}
      />
      <section className="workspace-panel">
        <div className="workspace-toolbar">
          <Segmented
            items={[{ id: "sheep", label: "羊只" }, { id: "pens", label: "圈舍" }]}
            value={view}
            onChange={setView}
          />
          <label className="inline-search">
            <MagnifyingGlass size={18} />
            <input value={filter} onChange={(event) => setFilter(event.target.value)} placeholder="筛选耳号、品种或圈舍" />
          </label>
        </div>
        {workspace.mode === "cloud" && workspace.projectionCoverage?.incompleteSheep ? (
          <ProjectionNotice>
            当前在场数量保留云端有效状态（{workspace.metrics.activeSheep.toLocaleString("zh-CN")} 只）；{baseline?.status === "loaded" ? `紧凑基线已展开，仍有 ${workspace.projectionCoverage.incompleteSheep.toLocaleString("zh-CN")} 只在云端缺少耳号、品种或性别字段，因此显示“资料未展开”，不猜填旧值。` : `紧凑基线未能读取（${baseline?.reason || "未知原因"}），其中 ${workspace.projectionCoverage.incompleteSheep.toLocaleString("zh-CN")} 只资料不完整，暂不猜填旧值。`}
          </ProjectionNotice>
        ) : null}
        <div className="table-scroll">
          {view === "sheep" ? (
            <table className="data-table">
              <thead><tr><th>耳号</th><th>品种</th><th>性别</th><th>生产阶段</th><th>当前圈舍</th><th>最近体重</th><th>更新时间</th></tr></thead>
              <tbody>
                {sheepRows.map((sheep) => (
                  <tr key={sheep.id}>
                    <td><strong>{sheep.earTag}</strong></td><td>{sheep.breed}</td><td>{sheep.sex}</td>
                    <td><span className="status-text">{sheep.stage}</span></td><td>{sheep.pen}</td>
                    <td>{sheep.weight == null ? "—" : `${sheep.weight} kg`}</td><td>{formatDateTime(sheep.updatedAt, timeZone)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <table className="data-table">
              <thead><tr><th>圈舍</th><th>用途</th><th>在场羊只</th><th>状态</th><th>最近更新</th></tr></thead>
              <tbody>
                {penRows.map((pen) => (
                  <tr key={pen.id}>
                    <td><strong>{pen.name}</strong></td><td>{pen.purpose}</td><td>{pen.headCount ?? "—"}</td>
                    <td><span className={`state-label ${pen.status === "正常" ? "success" : "warning"}`}>{pen.status}</span></td>
                    <td>{formatDateTime(pen.updatedAt, timeZone)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
        <footer className="panel-footer">{view === "sheep" ? `当前显示 ${sheepRows.length} 条记录` : `当前显示 ${penRows.length} 个有羊圈舍`}</footer>
      </section>
    </main>
  );
}

const entryGroups = [
  { id: "addSheep", title: "羊只建档", text: "创建耳号、品种、性别、入场与出生基线。", icon: Sheep },
  { id: "weight", title: "称重", text: "记录真实称重日期与体重，不覆盖历史。", icon: Scale },
  { id: "transfer", title: "转群", text: "按发生日期将羊只转入目标圈舍。", icon: ArrowsLeftRight },
  { id: "removal", title: "离场", text: "出售、死亡或淘汰，并保留可纠正事件。", icon: SignOut },
  { id: "health", title: "健康与免疫", text: "用药、疫苗、治疗与库存扣减。", icon: Heart },
  { id: "reproduction", title: "繁殖", text: "配种、孕检、产羔、断奶和系谱事实。", icon: Baby },
];

export function EntryPage({ workspace, onCreateRecord }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  return (
    <main className="page feature-page">
      <PageTop title="生产录入" description="每次录入都先形成可确认的业务动作，再进入事件历史。" />
      <div className="entry-layout">
        <section className="entry-action-list">
          {entryGroups.map(({ id, title, text, icon: Icon }) => (
            <button type="button" key={id} onClick={() => onCreateRecord(id)}>
              <Icon size={28} />
              <span><strong>{title}</strong><small>{text}</small></span>
              <Plus size={21} />
            </button>
          ))}
        </section>
        <aside className="workspace-panel entry-history">
          <div className="panel-heading"><h2>{workspace.mode === "cloud" ? "已同步事件" : "今日已录入"}</h2><span>{workspace.events.length} 条</span></div>
          <div className="simple-activity-list">
            {workspace.events.slice(0, 7).map((event) => (
              <article key={event.id}>
                <span className={`activity-mark ${event.status}`} />
                <div><strong>{event.label}</strong><small>{event.object} · {event.actor}</small></div>
                <time>{formatDateTime(event.at, timeZone)}</time>
              </article>
            ))}
          </div>
        </aside>
      </div>
    </main>
  );
}

export function FeedingPage({ workspace, onCreateRecord }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const [tab, setTab] = useState("records");
  return (
    <main className="page feature-page">
      <PageTop title="投喂" description="原料、配方、批次与投喂历史使用同一营养快照链路。" actionLabel="记录投喂" onAction={() => onCreateRecord("feed")} icon={BowlFood} />
      <section className="workspace-panel">
        <div className="workspace-toolbar">
          <Segmented
            items={[{ id: "records", label: "投喂记录" }, { id: "ingredients", label: "原料库" }, { id: "recipes", label: "配方" }]}
            value={tab}
            onChange={setTab}
          />
          <span className="toolbar-note">顿次统一为：早 / 中 / 晚 / 全天</span>
        </div>
        {workspace.mode === "cloud" ? <ProjectionNotice>投喂、原料与配方均读取云端基础投影；库存数量、营养计算与 TMR 监控尚未接入，因此不会显示演示数值。方式已按 App 语义显示为“限量投喂 / 自由采食”。</ProjectionNotice> : null}
        <div className="table-scroll">
          {tab === "records" ? (
            <table className="data-table">
              <thead><tr><th>发生时间</th><th>圈舍</th><th>顿次</th><th>配方</th><th>方式</th><th>投喂量</th><th>干物质</th></tr></thead>
              <tbody>{workspace.feedRecords.length ? workspace.feedRecords.map((record) => (
                <tr key={record.id}><td>{formatDateTime(record.at, timeZone)}</td><td><strong>{record.pen}</strong></td><td>{record.meal}</td><td>{record.recipe}</td><td>{record.mode}</td><td>{record.kilograms.toLocaleString("zh-CN")} kg</td><td>{record.dryMatter == null ? "—" : `${record.dryMatter.toLocaleString("zh-CN", { maximumFractionDigits: 1 })} kg`}</td></tr>
              )) : <tr><td colSpan="7"><div className="empty-state">暂无云端投喂记录。</div></td></tr>}</tbody>
            </table>
          ) : null}
          {tab === "ingredients" ? (
            <table className="data-table">
              <thead><tr><th>原料</th><th>类别</th><th>单位</th><th>干物质</th><th>可用库存</th></tr></thead>
              <tbody>{workspace.ingredients.length ? workspace.ingredients.map((item) => (
                <tr key={item.id}><td><strong>{item.name}</strong></td><td>{item.category}</td><td>{item.unit}</td><td>{item.dryMatter == null ? "—" : `${item.dryMatter}%`}</td><td>{item.stock == null ? "—" : `${item.stock.toLocaleString("zh-CN")} kg`}</td></tr>
              )) : <tr><td colSpan="5"><div className="empty-state">暂无云端原料目录。</div></td></tr>}</tbody>
            </table>
          ) : null}
          {tab === "recipes" ? (
            <table className="data-table">
              <thead><tr><th>配方</th><th>适用阶段</th><th>基准重量</th><th>CP</th><th>ME</th><th>NDF</th></tr></thead>
              <tbody>{workspace.recipes.length ? workspace.recipes.map((recipe) => (
                <tr key={recipe.id}><td><strong>{recipe.name}</strong></td><td>{recipe.stage}</td><td>{recipe.totalKg.toLocaleString("zh-CN")} kg</td><td>{recipe.cp == null ? "—" : `${recipe.cp}%`}</td><td>{recipe.me == null ? "—" : `${recipe.me} MJ/kg`}</td><td>{recipe.ndf == null ? "—" : `${recipe.ndf}%`}</td></tr>
              )) : <tr><td colSpan="6"><div className="empty-state">暂无云端配方。</div></td></tr>}</tbody>
            </table>
          ) : null}
        </div>
      </section>
    </main>
  );
}

export function TMRPage({ workspace, onCreateRecord }) {
  const plan = workspace.tmrPlan;
  return (
    <main className="page feature-page">
      <PageTop title="TMR 工作台" description="从配方、计划、生产批次到顿次完成与偏差确认。" actionLabel="新建 TMR 记录" onAction={() => onCreateRecord("feed")} icon={ForkKnife} />
      {workspace.mode === "cloud" ? <ProjectionNotice>配方与计划读取云端 TMR 实体；投喂批次、完成量与偏差监控尚未接入，因此不显示演示计划或虚构告警。录入只生成浏览器草稿。</ProjectionNotice> : null}
      <div className="tmr-workspace-grid">
        <section className="workspace-panel tmr-plan-panel">
          <div className="panel-heading"><h2>云端计划</h2><span>{plan ? `${plan.penCount} 个圈舍` : "暂无计划"}</span></div>
          {plan ? <div className="tmr-cloud-plan-summary"><strong>{plan.formulaName}</strong><small>{plan.granularity} · {plan.allocationMode} · 容差 {plan.tolerancePercent == null ? "—" : `${plan.tolerancePercent}%`}</small><small>早 {plan.morningShare == null ? "—" : `${plan.morningShare * 100}%`} · 中 {plan.noonShare == null ? "—" : `${plan.noonShare * 100}%`} · 晚 {plan.eveningShare == null ? "—" : `${plan.eveningShare * 100}%`}</small></div> : null}
          {workspace.tmrMeals.length ? workspace.tmrMeals.map((meal) => (
            <article className="tmr-plan-row" key={meal.id}>
              <span className={`tmr-plan-period ${meal.status}`}>{meal.period}</span>
              <div><strong>{meal.time}</strong><small>计划 {meal.planKg == null ? "—" : `${meal.planKg.toLocaleString("zh-CN")} kg`}</small></div>
              <div className="tmr-plan-progress"><span><i style={{ width: `${meal.progress ?? 0}%` }} /></span><small>{meal.actualKg.toLocaleString("zh-CN")} kg · {meal.progress == null ? "未计算" : `${meal.progress}%`}</small></div>
              {meal.status === "completed" ? <CheckCircle size={24} weight="fill" className="success-icon" /> : <Activity size={24} />}
            </article>
          )) : <div className="empty-state">暂无已接入的云端 TMR 顿次。</div>}
        </section>
        <section className="workspace-panel">
          <div className="panel-heading"><h2>配方与生产</h2><span>{workspace.recipes.length} 套云端配方</span></div>
          <div className="tmr-production-list">
          {workspace.recipes.length ? workspace.recipes.map((recipe) => (
              <article key={recipe.id}>
                <Package size={26} />
                <span><strong>{recipe.name}</strong><small>{recipe.stage} · 组配总量 {recipe.totalKg.toLocaleString("zh-CN")} kg</small></span>
                <b>云端</b>
              </article>
            )) : <div className="empty-state">暂无云端配方。</div>}
          </div>
        </section>
        <section className="workspace-panel tmr-monitor-panel">
          <div className="panel-heading"><h2>偏差监控</h2><span className="state-label warning">未接入</span></div>
          <div className="empty-state">云端偏差监控尚未接入，当前不显示演示告警。</div>
        </section>
      </div>
    </main>
  );
}

export function InsightsPage({ workspace }) {
  const isCloud = workspace.mode === "cloud";
  const insightData = workspace.insightData ?? {};
  const insights = [
    { label: "在场羊只", value: workspace.metrics.activeSheep, unit: "只", detail: isCloud ? "按云端有效状态与离场事件筛选" : "按演示工作区数据计算", icon: Sheep },
    { label: isCloud ? "近 30 天称重记录" : "近 30 天称重", value: isCloud ? (insightData.recentWeightCount ?? 0) : 86, unit: "次", detail: isCloud ? "来自真实 weight 实体" : "覆盖 67 只羊", icon: Scale },
    { label: "今日投喂量", value: isCloud ? (insightData.feedKilogramsToday ?? 0) : 602.4, unit: "kg", detail: isCloud ? "按投喂事件发生日期汇总" : "今日已记录", icon: BowlFood },
    { label: "云端规则", value: isCloud ? "—" : workspace.alerts.reduce((sum, alert) => sum + alert.count, 0), unit: isCloud ? "" : "项", detail: isCloud ? "网页端尚未接入规则计算" : "来自当前牧场规则", icon: WarningCircle },
  ];
  const chartSeries = isCloud ? [] : demoInsightSeries;
  const max = chartSeries.length ? Math.max(...chartSeries) : 0;
  return (
    <main className="page feature-page">
      <PageTop title="洞察" description="所有指标都从有效事件、历史圈舍暴露与营养快照重算。" />
      {workspace.mode === "cloud" ? <ProjectionNotice>当前指标仅展示已接入的云端实体统计；趋势、规则和营养分析未接入，不显示演示数值。</ProjectionNotice> : null}
      <section className="insight-metrics">
        {insights.map(({ label, value, unit, detail, icon: Icon }) => (
          <article key={label}><Icon size={27} /><span><small>{label}</small><strong>{typeof value === "number" ? value.toLocaleString("zh-CN") : value}<em>{unit}</em></strong><p>{detail}</p></span></article>
        ))}
      </section>
      <div className="insight-grid">
        <section className="workspace-panel trend-panel">
          <div className="panel-heading"><h2>育肥批次平均体重</h2><span>{isCloud ? "未接入" : "最近 8 周"}</span></div>
          {chartSeries.length ? <div className="bar-chart" aria-label="育肥批次最近八周平均体重趋势">
            {chartSeries.map((value, index) => (
              <div className="bar-item" key={`${value}-${index}`}>
                <span className="bar-value">{value}</span>
                <span className="bar-track"><i style={{ height: `${(value / max) * 100}%` }} /></span>
                <small>第{index + 1}周</small>
              </div>
            ))}
          </div> : <div className="empty-state">云端趋势分析尚未接入，当前不显示演示曲线。</div>}
        </section>
        <section className="workspace-panel">
          <div className="panel-heading"><h2>规则解释</h2><ShieldCheck size={24} /></div>
          <div className="rule-list">
            {workspace.alerts.length ? workspace.alerts.map((alert) => (
              <article key={alert.id}><span className={`rule-dot ${alert.tone}`} /><div><strong>{alert.title} · {alert.count}{alert.unit}</strong><p>{alert.description}</p></div></article>
            )) : <div className="empty-state">暂无已接入的云端规则结果。</div>}
          </div>
        </section>
      </div>
    </main>
  );
}

export function EventsPage({ workspace }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const [type, setType] = useState("all");
  const rows = type === "all" ? workspace.events : workspace.events.filter((event) => event.type === type);
  return (
    <main className="page feature-page">
      <PageTop title="事件记录" description="审计、纠正、撤销和远端重放都以事件为事实来源。" />
      <section className="workspace-panel">
        <div className="workspace-toolbar">
          <Segmented items={[{ id: "all", label: "全部" }, { id: "weight", label: "称重" }, { id: "feed", label: "投喂" }, { id: "health", label: "健康" }, { id: "transfer", label: "转群" }]} value={type} onChange={setType} />
          <span className="toolbar-note">{rows.length} 条</span>
        </div>
        <div className="table-scroll">
          <table className="data-table"><thead><tr><th>发生时间</th><th>事件</th><th>对象</th><th>操作人</th><th>同步状态</th><th>修订</th></tr></thead>
            <tbody>{rows.map((event) => (
              <tr key={event.id}><td>{formatDateTime(event.at, timeZone)}</td><td><strong>{event.label}</strong></td><td>{event.object}</td><td>{event.actor}</td><td><span className={`state-label ${event.status === "synced" ? "success" : "warning"}`}>{event.status === "synced" ? "已同步" : "本地草稿"}</span></td><td>{event.revision ? `#${event.revision}` : "—"}</td></tr>
            ))}</tbody>
          </table>
        </div>
      </section>
    </main>
  );
}

const capabilityRows = [
  ["读取牧场", "可用", "可用", "可用"],
  ["记录生产", "可用", "可用", "可用"],
  ["修改历史事实", "可用", "可用", "受限"],
  ["管理基础目录", "可用", "可用", "受限"],
  ["查看洞察", "可用", "可用", "按授权"],
  ["删除受保护事实", "可用", "受限", "不可用"],
  ["管理成员与牧场", "可用", "受限", "不可用"],
];

export function SettingsPage({ workspace, authState, isConfigured, onSignIn, onAppleSignIn, onSignOut, onReloadCloud }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [appleBusy, setAppleBusy] = useState(false);
  const [message, setMessage] = useState("");

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setMessage("");
    try {
      await onSignIn(email, password);
      setPassword("");
      setMessage("已登录并载入云端牧场。");
    } catch (error) {
      setMessage(error.message || "登录失败，请检查账号信息。");
    } finally {
      setBusy(false);
    }
  }

  async function submitApple() {
    setAppleBusy(true);
    setMessage("");
    try {
      await onAppleSignIn();
    } catch (error) {
      setMessage(error.message || "Apple 登录失败，请稍后重试。");
      setAppleBusy(false);
    }
  }

  return (
    <main className="page feature-page">
      <PageTop title="设置" description="账号、牧场权限、云端数据与网页端安全边界。" icon={Gear} />
      <div className="settings-grid">
        <section className="workspace-panel cloud-settings-card">
          <div className="panel-heading"><h2>Supabase 云端</h2>{workspace.mode === "cloud" ? <CloudCheck size={25} className="success-icon" /> : <CloudSlash size={25} />}</div>
          {workspace.mode === "cloud" ? (
            <div className="signed-in-state">
              <div className="connection-summary"><CloudCheck size={34} /><span><strong>已连接 {workspace.farm.name}</strong><small>{workspace.profile?.email} · {workspace.farm.roleName}</small></span></div>
              <dl><div><dt>云端修订</dt><dd>#{workspace.farm.revision?.toLocaleString("zh-CN")}</dd></div><div><dt>权限策略</dt><dd>RLS 已启用</dd></div><div><dt>当前模式</dt><dd>读取基础投影</dd></div></dl>
              <div className="settings-actions"><button type="button" className="secondary-button" onClick={onReloadCloud}><CloudArrowDown size={19} />刷新云端</button><button type="button" className="text-danger-button" onClick={onSignOut}><SignOut size={19} />退出登录</button></div>
            </div>
          ) : (
            <form className="auth-form" onSubmit={submit}>
              <p>{isConfigured ? "使用与 App 相同的账号登录；浏览器只持有可公开的 publishable key，数据访问由 RLS 决定。" : "当前未配置 Supabase 浏览器环境。"}</p>
              <label>邮箱<input type="email" required value={email} onChange={(event) => setEmail(event.target.value)} autoComplete="username" disabled={!isConfigured || busy} /></label>
              <label>密码<input type="password" required value={password} onChange={(event) => setPassword(event.target.value)} autoComplete="current-password" disabled={!isConfigured || busy} /></label>
              <button className="primary-button" type="submit" disabled={!isConfigured || busy}><SignIn size={20} />{busy ? "正在登录…" : "登录云端账号"}</button>
              <div className="auth-divider" aria-hidden="true"><span>或</span></div>
              <button className="apple-auth-button" type="button" onClick={submitApple} disabled={!isConfigured || busy || appleBusy}>
                <AppleLogo size={20} weight="fill" />
                {appleBusy ? "正在跳转 Apple…" : "使用 Apple 登录"}
              </button>
              <small className="auth-provider-note">使用 Supabase Apple OAuth；登录后会返回当前网页。Apple Provider 需要先配置 Apple Developer secret。</small>
              {message || authState.error ? <div className="form-message">{message || authState.error}</div> : null}
            </form>
          )}
        </section>

        <section className="workspace-panel security-boundary-card">
          <div className="panel-heading"><h2>网页写入边界</h2><LockKey size={24} /></div>
          <div className="boundary-list">
            <article><CheckCircle size={22} weight="fill" /><span><strong>真实云端读取</strong><small>登录后按成员身份、牧场和 RLS 读取投影与事件。</small></span></article>
            <article><CheckCircle size={22} weight="fill" /><span><strong>本地交互草稿</strong><small>录入、筛选、表格和 TMR 操作在网页内立即可验证。</small></span></article>
            <article className="pending"><WarningCircle size={22} weight="fill" /><span><strong>生产云写入仍受保护</strong><small>完整移植命令校验、设备身份、修订冲突、Outbox 与远端重放前，不伪装成“已提交”。</small></span></article>
          </div>
        </section>

        <section className="workspace-panel capability-card">
          <div className="panel-heading"><h2>角色能力</h2><UsersThree size={24} /></div>
          <div className="table-scroll"><table className="data-table compact-capability"><thead><tr><th>能力</th><th>所有者</th><th>管理员</th><th>成员</th></tr></thead><tbody>{capabilityRows.map((row) => <tr key={row[0]}>{row.map((cell, index) => <td key={`${row[0]}-${index}`}>{index === 0 ? <strong>{cell}</strong> : cell}</td>)}</tr>)}</tbody></table></div>
        </section>

        <section className="workspace-panel farm-summary-card">
          <div className="panel-heading"><h2>当前牧场</h2><Barn size={24} /></div>
          <dl className="farm-summary-list"><div><dt>名称</dt><dd>{workspace.farm.name}</dd></div><div><dt>数据来源</dt><dd>{workspace.mode === "cloud" ? "Supabase 基础投影；规则/TMR 为预览" : "本地演示数据"}</dd></div><div><dt>在场羊只</dt><dd>{workspace.metrics.activeSheep.toLocaleString("zh-CN")} 只</dd></div><div><dt>有效圈舍</dt><dd>{workspace.metrics.activePens.toLocaleString("zh-CN")} 个</dd></div>{workspace.mode === "cloud" && workspace.projectionCoverage?.incompleteSheep ? <div><dt>资料未展开</dt><dd>{workspace.projectionCoverage.incompleteSheep.toLocaleString("zh-CN")} 只</dd></div> : null}</dl>
        </section>
      </div>
    </main>
  );
}
