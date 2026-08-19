import {
  ArrowsLeftRight,
  Baby,
  Barn,
  BowlFood,
  CaretRight,
  CloudCheck,
  CloudSlash,
  FirstAid,
  Heart,
  Plus,
  PlusCircle,
  SignOut,
  WarningCircle,
} from "@phosphor-icons/react";
import { SheepGlyph as Sheep, WeightGlyph as Scale } from "./DomainIcons.jsx";

const eventIcons = {
  weight: Scale,
  feed: BowlFood,
  health: Heart,
  transfer: ArrowsLeftRight,
  reproduction: Baby,
  tmr: BowlFood,
  note: FirstAid,
};

const quickActions = [
  { id: "addSheep", label: "新建羊只", icon: Sheep },
  { id: "weight", label: "称重", icon: Scale },
  { id: "transfer", label: "转群", icon: ArrowsLeftRight },
  { id: "removal", label: "离场", icon: SignOut },
  { id: "feed", label: "记录投喂", icon: BowlFood },
  { id: "health", label: "记录健康", icon: Heart },
];

const metrics = [
  { key: "activeSheep", label: "在场羊只", unit: "只", icon: Sheep },
  { key: "activePens", label: "有羊圈舍", unit: "个", icon: Barn },
  { key: "feedsToday", label: "今日投喂", unit: "次", icon: BowlFood },
];

function formatLedgerDate(date = new Date(), timeZone = "Asia/Shanghai") {
  const parts = new Intl.DateTimeFormat("zh-CN", {
    month: "numeric",
    day: "numeric",
    weekday: "long",
    timeZone,
  }).formatToParts(date);
  const value = (type) => parts.find((part) => part.type === type)?.value ?? "";
  return `${value("month")}月${value("day")}日，${value("weekday")}`;
}

function timeText(value, timeZone = "Asia/Shanghai") {
  if (!value) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone,
  }).format(new Date(value));
}

function dayAndTime(value, timeZone = "Asia/Shanghai") {
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

function EventIcon({ type }) {
  const Icon = eventIcons[type] ?? FirstAid;
  return <Icon size={23} weight="regular" aria-hidden="true" />;
}

export function HomeDashboard({ workspace, onNavigate, onCreateRecord }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const baselineLoaded = workspace.projectionCoverage?.baseline?.status === "loaded";
  return (
    <main className="page home-page">
      <div className="page-command-row">
        <button className="primary-button" type="button" onClick={() => onCreateRecord("new")}>
          <PlusCircle size={21} weight="regular" />
          新建记录
        </button>
      </div>

      <div className="home-grid">
        <section className="ledger-card main-ledger" aria-label="今日牧场台账">
          <header className="ledger-date-header">
            <h1>{formatLedgerDate(new Date(), timeZone)}</h1>
            <p>{workspace.farm.name}</p>
          </header>

          <section className="ledger-section alerts-section">
            <div className="ledger-section-title">
              <h2>待办与异常{workspace.mode === "cloud" ? <small className="preview-badge">规则预览</small> : null}</h2>
              <button type="button" onClick={() => onNavigate("insights")}>查看全部</button>
            </div>
            <div className="alert-list">
              {workspace.alerts.length ? workspace.alerts.map((alert) => (
                <button
                  className="alert-row"
                  key={alert.id}
                  type="button"
                  onClick={() => onNavigate(alert.target)}
                  title={alert.description}
                >
                  <WarningCircle
                    className={`tone-${alert.tone}`}
                    size={29}
                    weight="fill"
                    aria-hidden="true"
                  />
                  <span className="alert-title">{alert.title}</span>
                  <strong>{alert.count}<small>{alert.unit}</small></strong>
                  <CaretRight size={21} weight="bold" />
                </button>
              )) : (
                <div className="empty-state compact-empty-state">
                  {workspace.mode === "cloud" ? "云端规则尚未接入网页端，当前不显示演示告警。" : "暂无待办与异常。"}
                </div>
              )}
            </div>
          </section>

          <section className="ledger-section events-section">
            <div className="ledger-section-title">
              <h2>最近事件</h2>
            </div>
            <div className="event-table-wrap">
              <table className="event-table compact-table">
                <thead>
                  <tr>
                    <th>时间</th>
                    <th>事件</th>
                    <th>对象</th>
                    <th>操作人</th>
                  </tr>
                </thead>
                <tbody>
                  {workspace.events.slice(0, 5).map((event) => (
                    <tr key={event.id}>
                      <td><span className="timeline-dot" />{timeText(event.at, timeZone)}</td>
                      <td><EventIcon type={event.type} /><span>{event.label}</span></td>
                      <td>{event.object}</td>
                      <td>{event.actor}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          <footer className="sync-footer">
            {workspace.mode === "cloud" ? (
              <>
                <CloudCheck size={20} weight="regular" />
                <strong>{baselineLoaded ? "云端基础投影与紧凑基线已同步" : "云端基础投影已同步"}</strong>
              </>
            ) : (
              <>
                <CloudSlash size={20} weight="regular" />
                <strong>演示数据</strong>
              </>
            )}
            <span className="sync-separator" />
            <span>{workspace.mode === "cloud" ? "规则与 TMR 顿次完成监控未接入 · " : ""}最后同步：{dayAndTime(workspace.lastSyncedAt, timeZone)}</span>
          </footer>
        </section>

        <aside className="home-side-column">
          <section className="ledger-card metric-strip" aria-label="牧场概览">
            {metrics.map(({ key, label, unit, icon: Icon }) => (
              <div className="metric-item" key={key}>
                <Icon size={39} weight="regular" aria-hidden="true" />
                <span>
                  <small>{label}</small>
                  <strong>{workspace.metrics[key].toLocaleString("zh-CN")}<em>{unit}</em></strong>
                </span>
              </div>
            ))}
          </section>

          <section className="ledger-card quick-actions" aria-label="快捷录入">
            {quickActions.map(({ id, label, icon: Icon }) => (
              <button type="button" key={id} onClick={() => onCreateRecord(id)}>
                <Icon size={40} weight="regular" aria-hidden="true" />
                <span>{label}</span>
              </button>
            ))}
          </section>

          <section className="ledger-card tmr-today">
            <div className="side-card-title">
              <h2>今日投喂与 TMR{workspace.mode === "cloud" ? <small className="preview-badge">未接入</small> : null}</h2>
              <button type="button" onClick={() => onCreateRecord("feed")}>记录 TMR 投喂</button>
            </div>
            <div className="tmr-meal-list">
              {workspace.tmrMeals.length ? workspace.tmrMeals.map((meal, index) => (
                <article className="tmr-meal" key={meal.id}>
                  <div className="meal-time-rail">
                    <span className="meal-period">{meal.period}</span>
                    <time>{meal.time}</time>
                    {index < workspace.tmrMeals.length - 1 ? <span className="meal-connector" /> : null}
                  </div>
                  <div className="meal-plan">
                    <small>计划</small>
                    <strong>{meal.time}</strong>
                  </div>
                  <div className="meal-actual">
                    <small>实际投喂</small>
                    <strong>{meal.actualKg.toLocaleString("zh-CN")}<em> kg</em></strong>
                    <div className="progress-row">
                      <span className="progress-track" aria-label={`完成 ${meal.progress}%`}>
                        <i style={{ width: `${meal.progress}%` }} />
                      </span>
                      <b>{meal.progress}%</b>
                    </div>
                  </div>
                </article>
              )) : (
                <div className="empty-state compact-empty-state">
                  {workspace.mode === "cloud" ? "今天暂无已接入的云端 TMR 投喂记录。" : "暂无投喂计划。"}
                </div>
              )}
            </div>
          </section>
        </aside>
      </div>
    </main>
  );
}
