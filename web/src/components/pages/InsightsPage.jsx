import { BowlFood } from "@phosphor-icons/react/BowlFood";
import { ShieldCheck } from "@phosphor-icons/react/ShieldCheck";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";
import { demoInsightSeries } from "../../data/demoData.js";
import { SheepGlyph as Sheep, WeightGlyph as Scale } from "../DomainIcons.jsx";
import { PageTop, ProjectionNotice } from "./FeaturePageShared.jsx";

export default function InsightsPage({ workspace }) {
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
