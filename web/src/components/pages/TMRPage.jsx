import { useMemo, useState } from "react";
import { BowlFood } from "@phosphor-icons/react/BowlFood";
import { CaretRight } from "@phosphor-icons/react/CaretRight";
import { CheckCircle } from "@phosphor-icons/react/CheckCircle";
import { ClipboardText } from "@phosphor-icons/react/ClipboardText";
import { Factory } from "@phosphor-icons/react/Factory";
import { ForkKnife } from "@phosphor-icons/react/ForkKnife";
import { Package } from "@phosphor-icons/react/Package";
import { Pulse } from "@phosphor-icons/react/Pulse";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";
import { PageTop, ProjectionNotice } from "./FeaturePageShared.jsx";

const routeMeta = {
  "tmr-feed": { title: "记录 TMR 投喂", description: "按圈舍、顿次、配方和实际重量记录投喂。", icon: BowlFood },
  "tmr-produce": { title: "制作 TMR", description: "按配方和目标批量形成生产草稿并核对用料。", icon: ForkKnife },
  "tmr-batches": { title: "TMR 批次", description: "查看批次状态、配方、目标量和实际完成量。", icon: Package },
  "tmr-monitor": { title: "完成与偏差监控", description: "对照顿次计划、实际投喂和容差。", icon: Pulse },
  "tmr-plans": { title: "投喂计划", description: "查看圈舍分配、顿次比例和允许偏差。", icon: ClipboardText },
  "tmr-formulas": { title: "TMR 配方", description: "查看配方组分、阶段和营养快照。", icon: Factory },
};

const hubItems = Object.entries(routeMeta).map(([id, meta]) => ({ id, ...meta }));

function TMRNotice({ workspace, mode }) {
  if (workspace.mode !== "cloud") return null;
  const real = ["tmr-plans", "tmr-formulas"].includes(mode);
  return <ProjectionNotice>{real ? "此页读取真实 tmrFeedingPlan / tmrFormula 云端投影；网页修改仍只形成浏览器草稿。" : "TMR 批次、顿次完成量和偏差监控尚未接入云端投影；不显示演示值或虚构完成状态。"}</ProjectionNotice>;
}

function MealsMonitor({ workspace }) {
  if (!workspace.tmrMeals.length) return <div className="open-empty-state page-empty"><strong>暂无可读取的顿次状态</strong><span>云端完成量和偏差监控接入后会显示在这里。</span></div>;
  return (
    <div className="monitor-meal-list">
      {workspace.tmrMeals.map((meal) => {
        const delta = meal.planKg ? Math.round((meal.actualKg - meal.planKg) / meal.planKg * 100) : null;
        return (
          <article key={meal.id}>
            <span className={`meal-state-icon ${meal.status}`}>{meal.status === "completed" ? <CheckCircle size={25} weight="fill" /> : <Pulse size={25} />}</span>
            <span><strong>{meal.period}料 · {meal.time}</strong><small>计划 {meal.planKg.toLocaleString("zh-CN")} kg · 实际 {meal.actualKg.toLocaleString("zh-CN")} kg</small></span>
            <div className="monitor-progress"><span><i style={{ width: `${Math.min(meal.progress, 100)}%` }} /></span><b>{meal.progress}%</b></div>
            <em className={delta != null && Math.abs(delta) > 5 ? "danger" : "neutral"}>{delta == null ? "—" : `${delta > 0 ? "+" : ""}${delta}%`}</em>
          </article>
        );
      })}
    </div>
  );
}

function FormulaTable({ workspace }) {
  return (
    <div className="table-scroll"><table className="data-table"><thead><tr><th>配方</th><th>适用阶段</th><th>基准重量</th><th>CP</th><th>ME</th><th>NDF</th></tr></thead><tbody>
      {workspace.recipes.length ? workspace.recipes.map((recipe) => <tr key={recipe.id}><td><strong>{recipe.name}</strong></td><td>{recipe.stage}</td><td>{recipe.totalKg.toLocaleString("zh-CN")} kg</td><td>{recipe.cp == null ? "—" : `${recipe.cp}%`}</td><td>{recipe.me == null ? "—" : `${recipe.me} MJ/kg`}</td><td>{recipe.ndf == null ? "—" : `${recipe.ndf}%`}</td></tr>) : <tr><td colSpan="6"><div className="empty-state">暂无可读取配方。</div></td></tr>}
    </tbody></table></div>
  );
}

function ProduceDraft({ workspace }) {
  const [formula, setFormula] = useState(workspace.recipes[0]?.id ?? "");
  const [kilograms, setKilograms] = useState("1000");
  const [draft, setDraft] = useState(null);
  const selectedFormula = workspace.recipes.find((recipe) => recipe.id === formula);
  const multiplier = selectedFormula?.totalKg ? Number(kilograms || 0) / selectedFormula.totalKg : 0;
  const estimated = useMemo(() => [
    { name: "配方基准", kilograms: Number(kilograms || 0) },
    { name: "批次数量系数", kilograms: multiplier },
  ], [kilograms, multiplier]);
  return (
    <div className="produce-layout">
      <form className="production-draft-form" onSubmit={(event) => { event.preventDefault(); setDraft({ formula: selectedFormula?.name ?? "未选择配方", kilograms: Number(kilograms), at: new Date().toISOString() }); }}>
        <label><span>选择配方</span><select required value={formula} onChange={(event) => setFormula(event.target.value)}><option value="">请选择</option>{workspace.recipes.map((recipe) => <option value={recipe.id} key={recipe.id}>{recipe.name}</option>)}</select></label>
        <label><span>目标生产量（kg）</span><input required min="0.1" step="0.1" type="number" value={kilograms} onChange={(event) => setKilograms(event.target.value)} /></label>
        <div className="draft-calculation">{estimated.map((item) => <div key={item.name}><span>{item.name}</span><strong>{item.name === "配方基准" ? `${item.kilograms.toLocaleString("zh-CN")} kg` : `${item.kilograms.toLocaleString("zh-CN", { maximumFractionDigits: 2 })} ×`}</strong></div>)}</div>
        <button className="primary-button" type="submit">生成生产草稿</button>
      </form>
      <aside className="draft-preview"><p className="eyebrow">DRAFT</p><h2>生产草稿</h2>{draft ? <><CheckCircle size={30} weight="fill" /><strong>{draft.formula}</strong><p>目标 {draft.kilograms.toLocaleString("zh-CN")} kg</p><small>仅保存在当前页面，未提交云端，也不会改变库存。</small></> : <><Factory size={32} /><p>选择配方和目标量后生成可核对草稿。</p></>}</aside>
    </div>
  );
}

export default function TMRPage({ workspace, mode = "tmr", onCreateRecord, onNavigate }) {
  const plan = workspace.tmrPlan;
  if (mode === "tmr") {
    return (
      <main className="page feature-page">
        <PageTop title="TMR 工作台" description="从配方、计划、生产批次到顿次完成与偏差确认。" actionLabel="记录 TMR 投喂" onAction={() => onCreateRecord("feed")} icon={ForkKnife} />
        <TMRNotice workspace={workspace} mode={mode} />
        <section className="tmr-overview-band">
          <div><p className="eyebrow">CURRENT PLAN</p><h2>{plan?.formulaName ?? "暂无有效计划"}</h2><span>{plan ? `${plan.penCount} 个圈舍 · ${plan.granularity} · 容差 ${plan.tolerancePercent ?? "—"}%` : "请先在投喂计划中配置圈舍和配方。"}</span></div>
          <button type="button" onClick={() => onNavigate("tmr-plans")}>查看计划 <CaretRight size={17} /></button>
        </section>
        <section className="tmr-hub-grid">
          {hubItems.map(({ id, title, description, icon: Icon }) => <button type="button" key={id} onClick={() => onNavigate(id)}><Icon size={27} /><span><strong>{title}</strong><small>{description}</small></span><CaretRight size={19} weight="bold" /></button>)}
        </section>
        <section className="workspace-panel flat-panel"><div className="panel-heading"><h2>今日顿次</h2><button type="button" onClick={() => onNavigate("tmr-monitor")}>查看监控</button></div><MealsMonitor workspace={workspace} /></section>
      </main>
    );
  }

  const meta = routeMeta[mode] ?? routeMeta["tmr-monitor"];
  return (
    <main className="page feature-page">
      <PageTop title={meta.title} description={meta.description} actionLabel={mode === "tmr-feed" ? "记录投喂" : undefined} onAction={() => onCreateRecord("feed")} icon={meta.icon} />
      <TMRNotice workspace={workspace} mode={mode} />
      <button className="text-button back-link standalone-back" type="button" onClick={() => onNavigate("tmr")}>返回 TMR 工作台</button>
      {mode === "tmr-feed" ? <section className="workspace-panel flat-panel"><div className="panel-heading"><h2>最近 TMR 投喂</h2><span>{workspace.feedRecords.length} 条</span></div><div className="tmr-feed-cards">{workspace.feedRecords.slice(0, 8).map((record) => <article key={record.id}><BowlFood size={23} /><span><strong>{record.pen} · {record.meal}</strong><small>{record.recipe} · {record.kilograms.toLocaleString("zh-CN")} kg</small></span></article>)}</div></section> : null}
      {mode === "tmr-produce" ? <ProduceDraft workspace={workspace} /> : null}
      {mode === "tmr-batches" ? (workspace.tmrMeals.length ? <section className="workspace-panel flat-panel"><div className="panel-heading"><h2>今日批次视图</h2><span>演示顿次</span></div><MealsMonitor workspace={workspace} /></section> : <div className="open-empty-state page-empty"><strong>暂无可读取的 TMR 批次</strong><span>批次实体接入云端后会按生产时间显示。</span></div>) : null}
      {mode === "tmr-monitor" ? <section className="workspace-panel flat-panel"><div className="panel-heading"><h2>顿次完成与偏差</h2><span className="state-label warning">容差 ±{plan?.tolerancePercent ?? 5}%</span></div><MealsMonitor workspace={workspace} /></section> : null}
      {mode === "tmr-plans" ? <section className="workspace-panel flat-panel"><div className="panel-heading"><h2>当前投喂计划</h2><ClipboardText size={24} /></div>{plan ? <dl className="plan-detail-list"><div><dt>配方</dt><dd>{plan.formulaName}</dd></div><div><dt>覆盖圈舍</dt><dd>{plan.penCount} 个</dd></div><div><dt>分配方式</dt><dd>{plan.allocationMode}</dd></div><div><dt>顿次比例</dt><dd>早 {plan.morningShare == null ? "—" : `${plan.morningShare * 100}%`} · 中 {plan.noonShare == null ? "—" : `${plan.noonShare * 100}%`} · 晚 {plan.eveningShare == null ? "—" : `${plan.eveningShare * 100}%`}</dd></div><div><dt>允许偏差</dt><dd>±{plan.tolerancePercent ?? "—"}%</dd></div></dl> : <div className="empty-state">暂无有效计划。</div>}</section> : null}
      {mode === "tmr-formulas" ? <section className="workspace-panel flat-panel"><div className="panel-heading"><h2>配方目录</h2><span>{workspace.recipes.length} 套</span></div><FormulaTable workspace={workspace} /></section> : null}
    </main>
  );
}
