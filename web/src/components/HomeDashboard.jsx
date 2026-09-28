import { useMemo } from "react";
import { ArrowsLeftRight } from "@phosphor-icons/react/ArrowsLeftRight";
import { Barn } from "@phosphor-icons/react/Barn";
import { BowlFood } from "@phosphor-icons/react/BowlFood";
import { CaretRight } from "@phosphor-icons/react/CaretRight";
import { CloudCheck } from "@phosphor-icons/react/CloudCheck";
import { Plus } from "@phosphor-icons/react/Plus";
import { Scales } from "@phosphor-icons/react/Scales";
import { Sun } from "@phosphor-icons/react/Sun";
import { Tag } from "@phosphor-icons/react/Tag";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";

const metrics = [
  { key: "activeSheep", label: "在场羊只", unit: "只", icon: Tag, tone: "green", page: "flock" },
  { key: "activePens", label: "有羊圈舍", unit: "个", icon: Barn, tone: "gold", page: "pens" },
  { key: "feedsToday", label: "今日投喂", unit: "次", icon: BowlFood, tone: "blue", page: "feeding" },
];
const actions = [
  { id: "weight", label: "称重", detail: "记录体重，关注生长", icon: Scales, tone: "green" },
  { id: "transfer", label: "转群", detail: "调整圈舍，优化管理", icon: ArrowsLeftRight, tone: "gold" },
  { id: "feed", label: "投喂", detail: "记录投喂，掌握饲喂情况", icon: BowlFood, tone: "blue" },
];
const count = (value) => Number.isFinite(value) ? value.toLocaleString("zh-CN") : "—";

function GlassIcon({ icon: Icon, tone, sheep = false }) {
  return sheep
    ? <span className="sky-icon green" aria-hidden="true"><Tag size={36} weight="bold" /></span>
    : <span className={`sky-icon ${tone}`} aria-hidden="true"><Icon size={36} weight="bold" /></span>;
}

function eventTone(event) {
  if (event.type === "weight" || event.scope === "weight") return "green";
  if (/feed|tmr/i.test(event.type ?? event.scope ?? "")) return "blue";
  if (event.type === "transfer" || event.scope === "transfer") return "gold";
  return "neutral";
}

function displayTime(value, timeZone, now) {
  const date = new Date(value);
  if (!value || !Number.isFinite(date.getTime())) return "时间未记录";
  const day = new Intl.DateTimeFormat("en-CA", { timeZone });
  const sameDay = day.format(date) === day.format(now);
  return new Intl.DateTimeFormat("zh-CN", {
    ...(sameDay ? {} : { year: "numeric", month: "2-digit", day: "2-digit" }),
    hour: "2-digit", minute: "2-digit", hour12: false, timeZone,
  }).format(date);
}

export function HomeDashboard({ workspace, onNavigate, onCreateRecord }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const now = new Date();
  const dateText = new Intl.DateTimeFormat("zh-CN", { month: "long", day: "numeric", timeZone }).format(now)
    + " " + new Intl.DateTimeFormat("zh-CN", { weekday: "long", timeZone }).format(now);
  const recentEvents = useMemo(() => [...(workspace.events ?? [])]
    .sort((a, b) => (Date.parse(b.at) || 0) - (Date.parse(a.at) || 0)).slice(0, 3), [workspace.events]);
  const alerts = workspace.alerts ?? [];
  const meals = workspace.tmrMeals ?? [];
  const weather = workspace.weather;

  return (
    <main className="page sky-home">
      <section className="sky-overview" aria-label="牧场概览">
        <div className="sky-intro">
          <h1><span>今日</span>牧场</h1>
          <p className="sky-date">{dateText}</p>
          <p className="sky-greeting">好好照顾每一只羊，让牧场更美好。</p>
          {weather ? <p className="sky-weather"><Sun size={18} />{weather.temperature}° {weather.condition}{weather.location ? ` · ${weather.location}` : ""}</p> : null}
        </div>
        <div className="sky-metrics">
          {metrics.map(({ key, label, unit, icon, tone, page }) => (
            <button key={key} className="sky-metric" type="button" onClick={() => onNavigate(page)}>
              <GlassIcon icon={icon} tone={tone} />
              <span className="sky-metric-copy"><span>{label}</span><strong>{count(workspace.metrics[key])}<small>{unit}</small></strong></span>
            </button>
          ))}
        </div>
      </section>

      <div className="sky-workspace-grid">
        <section className="sky-panel sky-production" aria-label="生产状态">
          <div className="sky-panel-heading"><h2>生产档案</h2><span>核心数据，一目了然</span></div>
          <button className="sky-production-row" type="button" onClick={() => onNavigate("flock")}>
            <GlassIcon sheep />
            <span className="sky-row-copy"><strong>羊只档案</strong><small>记录每一只羊的成长轨迹</small><span className="sky-row-details">个体信息<span>·</span>生长记录<span>·</span>健康管理<span>·</span>繁殖记录</span></span>
            <CaretRight size={23} />
          </button>
          <button className="sky-production-row" type="button" onClick={() => onNavigate("pens")}>
            <GlassIcon icon={Barn} tone="blue" />
            <span className="sky-row-copy"><strong>圈舍状态</strong><small>查看各圈舍羊只分布与状态</small><span className="sky-row-details">圈舍信息<span>·</span>存栏数量<span>·</span>羊只状态<span>·</span>管理记录</span></span>
            <CaretRight size={23} />
          </button>
        </section>

        <section className="sky-panel sky-actions" aria-labelledby="today-actions-title">
          <div className="sky-panel-heading">
            <h2 id="today-actions-title">今日操作</h2>
            <button className="sky-new-record" type="button" onClick={() => onCreateRecord("new")}><Plus size={21} weight="bold" />新建记录</button>
          </div>
          <div className="sky-action-list">
            {actions.map(({ id, label, detail, icon, tone }) => (
              <button key={id} type="button" onClick={() => onCreateRecord(id)}>
                <GlassIcon icon={icon} tone={tone} />
                <span className="sky-row-copy"><strong>{label}</strong><small>{detail}</small></span><CaretRight size={20} />
              </button>
            ))}
          </div>
        </section>
      </div>

      <section className="sky-panel sky-activity" aria-labelledby="recent-activity-title">
        <div className="sky-panel-heading"><div className="sky-heading-group"><h2 id="recent-activity-title">最近动态</h2><span>最新操作记录</span></div><button className="sky-text-link" type="button" onClick={() => onNavigate("events")}>查看全部<CaretRight size={16} /></button></div>
        {recentEvents.length ? <div className="sky-activity-list">{recentEvents.map(event => (
          <button className={`sky-activity-row ${eventTone(event)}`} key={event.id} type="button" onClick={() => onNavigate("events", { selectedID: event.id })}>
            <span className="sky-event-dot" aria-hidden="true" />
            <time dateTime={event.at || undefined}>{displayTime(event.at, timeZone, now)}</time>
            <strong>{event.object ? `${event.object} · ` : ""}{event.label}</strong>
            <span className="sky-event-detail">{event.detail || event.note || "查看记录详情"}</span>
            <span className="sky-event-kind">{event.status === "synced" ? event.label : "浏览器草稿"}</span>
          </button>
        ))}</div> : <div className="sky-empty"><strong>还没有生产记录</strong><p>从「新建记录」开始，牧场的每一次变化都会留在这里。</p></div>}
      </section>

      {alerts.length || meals.length ? <div className="sky-operational-context">
        {alerts.length ? <section className="sky-panel"><div className="sky-panel-heading"><h2>待办与异常</h2><button className="sky-text-link" type="button" onClick={() => onNavigate("alerts")}>查看全部<CaretRight size={16} /></button></div>{alerts.map(alert => <button key={alert.id} className="operational-row" type="button" onClick={() => onNavigate("alerts", { selectedID: alert.id })}><WarningCircle className={`tone-${alert.tone}`} size={25} /><span className="row-copy"><strong>{alert.title}</strong><small>{alert.description}</small></span><span className="row-value">{alert.count}<small>{alert.unit}</small></span><CaretRight size={18} /></button>)}</section> : null}
        {meals.length ? <section className="sky-panel"><div className="sky-panel-heading"><h2>今日投喂与 TMR</h2><button className="sky-text-link" type="button" onClick={() => onNavigate("tmr")}>工作台<CaretRight size={16} /></button></div>{meals.map(meal => <button key={meal.id} className="sky-meal-row" type="button" onClick={() => onNavigate("tmr-monitor")}><strong>{meal.period}</strong><time>{meal.time}</time><span>计划 {meal.planKg == null ? "未关联" : `${count(meal.planKg)} kg`}</span><span>实际 {count(meal.actualKg)} kg</span><CaretRight size={18} /></button>)}</section> : null}
      </div> : null}
      <footer className="sky-home-footer">
        <span>{workspace.mode === "cloud" && workspace.lastSyncedAt ? <><CloudCheck size={16} />云端读取 · {displayTime(workspace.lastSyncedAt, timeZone, now)}</> : workspace.mode === "cloud" ? "等待云端读取" : "视觉预览 · 示例数据"}</span>
        <div><button type="button" onClick={() => onNavigate("alerts")}>待办与异常</button><button type="button" onClick={() => onNavigate("tmr")}>投喂与 TMR</button><button type="button" onClick={() => onNavigate("events", { exportHint: true })}>记录导出</button></div>
      </footer>
    </main>
  );
}
