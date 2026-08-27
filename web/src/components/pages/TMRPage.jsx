import { Pulse as Activity } from "@phosphor-icons/react/Pulse";
import { CheckCircle } from "@phosphor-icons/react/CheckCircle";
import { ForkKnife } from "@phosphor-icons/react/ForkKnife";
import { Package } from "@phosphor-icons/react/Package";
import { PageTop, ProjectionNotice } from "./FeaturePageShared.jsx";

export default function TMRPage({ workspace, onCreateRecord }) {
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
