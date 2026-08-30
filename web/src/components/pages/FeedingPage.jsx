import { BowlFood } from "@phosphor-icons/react/BowlFood";
import { CaretRight } from "@phosphor-icons/react/CaretRight";
import { ChartLineUp } from "@phosphor-icons/react/ChartLineUp";
import { ClipboardText } from "@phosphor-icons/react/ClipboardText";
import { ForkKnife } from "@phosphor-icons/react/ForkKnife";
import { Package } from "@phosphor-icons/react/Package";
import { Pulse } from "@phosphor-icons/react/Pulse";
import { Scales } from "@phosphor-icons/react/Scales";
import { formatDateTime, PageTop, ProjectionNotice } from "./FeaturePageShared.jsx";

const tmrActions = [
  { id: "tmr-feed", label: "记录 TMR 投喂", detail: "按圈舍、顿次与配方记录实际投喂", icon: BowlFood },
  { id: "tmr-produce", label: "制作 TMR", detail: "选择配方并形成生产批次草稿", icon: ForkKnife },
  { id: "tmr-batches", label: "TMR 批次", detail: "查看生产批次与用料快照", icon: Package },
  { id: "tmr-monitor", label: "完成与偏差监控", detail: "核对计划、实际量和偏差", icon: Pulse },
  { id: "tmr-plans", label: "投喂计划", detail: "圈舍、顿次分配与容差", icon: ClipboardText },
  { id: "tmr-formulas", label: "TMR 配方", detail: "配方组分与营养快照", icon: ChartLineUp },
];

function FeedTable({ workspace }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  return (
    <div className="table-scroll"><table className="data-table"><thead><tr><th>发生时间</th><th>圈舍</th><th>顿次</th><th>配方</th><th>方式</th><th>投喂量</th><th>干物质</th></tr></thead><tbody>
      {workspace.feedRecords.length ? workspace.feedRecords.map((record) => <tr key={record.id}><td>{formatDateTime(record.at, timeZone)}</td><td><strong>{record.pen}</strong></td><td>{record.meal}</td><td>{record.recipe}</td><td>{record.mode}</td><td>{record.kilograms.toLocaleString("zh-CN")} kg</td><td>{record.dryMatter == null ? "—" : `${record.dryMatter.toLocaleString("zh-CN", { maximumFractionDigits: 1 })} kg`}</td></tr>) : <tr><td colSpan="7"><div className="empty-state">暂无云端投喂记录。</div></td></tr>}
    </tbody></table></div>
  );
}

function IngredientTable({ workspace }) {
  return (
    <div className="table-scroll"><table className="data-table"><thead><tr><th>原料</th><th>类别</th><th>单位</th><th>干物质</th><th>可用库存</th><th>库存状态</th></tr></thead><tbody>
      {workspace.ingredients.length ? workspace.ingredients.map((item) => <tr key={item.id}><td><strong>{item.name}</strong></td><td>{item.category}</td><td>{item.unit}</td><td>{item.dryMatter == null ? "—" : `${item.dryMatter}%`}</td><td>{item.stock == null ? "—" : `${item.stock.toLocaleString("zh-CN")} kg`}</td><td><span className={`state-label ${item.stock == null ? "neutral" : item.stock < 800 ? "warning" : "success"}`}>{item.stock == null ? "未接入" : item.stock < 800 ? "需关注" : "充足"}</span></td></tr>) : <tr><td colSpan="6"><div className="empty-state">暂无云端原料目录。</div></td></tr>}
    </tbody></table></div>
  );
}

export default function FeedingPage({ workspace, mode = "feeding", onCreateRecord, onNavigate }) {
  const isHistory = mode === "feed-history";
  const isIngredients = mode === "ingredients";

  if (isHistory || isIngredients) {
    return (
      <main className="page feature-page">
        <PageTop title={isHistory ? "投喂历史" : "原料与库存"} description={isHistory ? "按发生时间查看投喂事实与营养快照，不覆盖历史。" : "维护原料目录、营养值和可用库存。"} actionLabel={isHistory ? "记录投喂" : undefined} onAction={() => onCreateRecord("feed")} icon={BowlFood} />
        {workspace.mode === "cloud" ? <ProjectionNotice>{isHistory ? "读取真实 feed 投影；网页新增仍只生成浏览器草稿。" : "原料目录读取真实云端投影；库存数量尚未接入时显示“—”。"}</ProjectionNotice> : null}
        <section className="workspace-panel flat-panel">
          <div className="workspace-toolbar"><button className="text-button back-link" type="button" onClick={() => onNavigate("feeding")}>返回投喂工作台</button><span className="toolbar-note">{isHistory ? `${workspace.feedRecords.length} 条记录` : `${workspace.ingredients.length} 种原料`}</span></div>
          {isHistory ? <FeedTable workspace={workspace} /> : <IngredientTable workspace={workspace} />}
        </section>
      </main>
    );
  }

  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const dateKey = (value) => new Intl.DateTimeFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit", timeZone }).format(new Date(value));
  const todayKey = dateKey(new Date());
  const todayKg = workspace.feedRecords.filter((record) => dateKey(record.at) === todayKey).reduce((sum, record) => sum + record.kilograms, 0);
  return (
    <main className="page feature-page feeding-hub-page">
      <PageTop title="投喂" description="与 App 一致：TMR、直接投喂、营养分析、历史、原料与库存都从这里进入。" actionLabel="记录直接投喂" onAction={() => onCreateRecord("feed")} icon={BowlFood} />
      {workspace.mode === "cloud" ? <ProjectionNotice>投喂、原料、配方和计划读取真实云端投影；TMR 批次与偏差监控尚未接入，相关页面会明确显示空状态。</ProjectionNotice> : null}
      <section className="feeding-summary-row">
        <article><BowlFood size={25} /><span><small>今日记录</small><strong>{workspace.metrics.feedsToday}<em>次</em></strong></span></article>
        <article><Scales size={25} /><span><small>今日投喂量</small><strong>{todayKg.toLocaleString("zh-CN", { maximumFractionDigits: 1 })}<em>kg</em></strong></span></article>
        <article><Package size={25} /><span><small>可用配方</small><strong>{workspace.recipes.length}<em>套</em></strong></span></article>
      </section>
      <div className="feeding-hub-layout">
        <section className="feeding-hub-section">
          <div className="group-heading"><span><p className="eyebrow">TMR</p><h2>全混合日粮</h2><p>从配方、计划、生产到实际投喂和偏差确认。</p></span><button type="button" onClick={() => onNavigate("tmr")}>打开工作台 <CaretRight size={16} /></button></div>
          <div className="feeding-action-grid">
            {tmrActions.map(({ id, label, detail, icon: Icon }) => (
              <button type="button" key={id} onClick={() => onNavigate(id)}><Icon size={24} /><span><strong>{label}</strong><small>{detail}</small></span><CaretRight size={18} weight="bold" /></button>
            ))}
          </div>
        </section>

        <section className="feeding-hub-section">
          <div className="group-heading"><span><p className="eyebrow">DIRECT FEEDING</p><h2>直接投喂与槽况</h2><p>记录单一或组合原料，并保留圈舍、顿次与数量。</p></span></div>
          <div className="management-action-list two-up">
            <button type="button" onClick={() => onCreateRecord("feed")}><BowlFood size={23} /><span><strong>记录投喂</strong><small>按圈舍记录实际饲喂量</small></span><CaretRight size={18} weight="bold" /></button>
            <button type="button" onClick={() => onCreateRecord("note")}><ClipboardText size={23} /><span><strong>槽况观察</strong><small>记录剩料、采食和现场异常</small></span><CaretRight size={18} weight="bold" /></button>
          </div>
        </section>

        <section className="feeding-hub-section">
          <div className="group-heading"><span><p className="eyebrow">DATA</p><h2>营养与基础资料</h2><p>分析、历史、原料目录和库存保持同一数据语义。</p></span></div>
          <div className="management-action-list two-up">
            <button type="button" onClick={() => onNavigate("insights", { focus: "intake" })}><ChartLineUp size={23} /><span><strong>营养与采食分析</strong><small>查看投喂量与营养指标</small></span><CaretRight size={18} weight="bold" /></button>
            <button type="button" onClick={() => onNavigate("feed-history")}><ClipboardText size={23} /><span><strong>投喂历史</strong><small>{workspace.feedRecords.length} 条可用记录</small></span><CaretRight size={18} weight="bold" /></button>
            <button type="button" onClick={() => onNavigate("ingredients")}><Package size={23} /><span><strong>原料库与库存</strong><small>{workspace.ingredients.length} 种可用原料</small></span><CaretRight size={18} weight="bold" /></button>
          </div>
        </section>
      </div>
    </main>
  );
}
