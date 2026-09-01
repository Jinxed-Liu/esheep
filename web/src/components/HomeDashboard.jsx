import { ArrowsLeftRight } from "@phosphor-icons/react/ArrowsLeftRight";
import { Barn } from "@phosphor-icons/react/Barn";
import { BowlFood } from "@phosphor-icons/react/BowlFood";
import { CaretRight } from "@phosphor-icons/react/CaretRight";
import { CheckCircle } from "@phosphor-icons/react/CheckCircle";
import { CloudCheck } from "@phosphor-icons/react/CloudCheck";
import { DownloadSimple } from "@phosphor-icons/react/DownloadSimple";
import { Plus } from "@phosphor-icons/react/Plus";
import { Scales } from "@phosphor-icons/react/Scales";
import { SignOut } from "@phosphor-icons/react/SignOut";
import { Sun } from "@phosphor-icons/react/Sun";
import { Tag } from "@phosphor-icons/react/Tag";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";

const quickActions = [
  { id: "addSheep", label: "新建羊只", icon: Tag },
  { id: "weight", label: "称重", icon: Scales },
  { id: "transfer", label: "转群", icon: ArrowsLeftRight },
  { id: "removal", label: "离场", icon: SignOut },
  { id: "feed", label: "投喂", icon: BowlFood },
  { id: "export", label: "记录导出", icon: DownloadSimple },
];

const metrics = [
  { key: "activeSheep", label: "在场羊只", unit: "只", icon: Tag },
  { key: "activePens", label: "有羊圈舍", unit: "个", icon: Barn },
  { key: "feedsToday", label: "今日投喂", unit: "次", icon: BowlFood },
];

function dateParts(date = new Date(), timeZone = "Asia/Shanghai") {
  const parts = new Intl.DateTimeFormat("zh-CN", {
    month: "numeric",
    day: "numeric",
    weekday: "long",
    timeZone,
  }).formatToParts(date);
  const read = (type) => parts.find((part) => part.type === type)?.value ?? "";
  return {
    dateText: `${read("month")}月${read("day")}日，${read("weekday")}`,
    yearText: new Intl.DateTimeFormat("zh-CN", { year: "numeric", timeZone }).format(date),
  };
}

function syncTime(value, timeZone) {
  if (!value) return "尚未同步";
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone,
  }).format(new Date(value));
}

function ProductionRow({ icon: Icon, title, detail, value, unit, onClick }) {
  return (
    <button className="production-row" type="button" onClick={onClick}>
      <span className="row-icon"><Icon size={23} /></span>
      <span className="row-copy"><strong>{title}</strong><small>{detail}</small></span>
      <span className="row-value">{value.toLocaleString("zh-CN")}<small>{unit}</small></span>
      <CaretRight size={19} weight="bold" />
    </button>
  );
}

export function HomeDashboard({ workspace, onNavigate, onCreateRecord }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const { dateText, yearText } = dateParts(new Date(), timeZone);
  const weather = workspace.weather;
  const alerts = workspace.alerts ?? [];
  const tmrMeals = workspace.tmrMeals ?? [];

  function runQuickAction(id) {
    if (id === "export") {
      onNavigate("events", { exportHint: true });
      return;
    }
    onCreateRecord(id);
  }

  return (
    <main className="page home-page">
      <div className="home-layout">
        <section className="home-briefing">
          <header className="briefing-hero">
            <div className="briefing-title">
              <p className="eyebrow">{yearText} · {workspace.farm.name}</p>
              <h1>{dateText}</h1>
              <div className="weather-line">
                <Sun size={22} weight="duotone" />
                {weather ? (
                  <span><strong>{weather.temperature}°</strong> {weather.condition}{weather.wind ? ` · ${weather.wind}` : ""}{weather.humidity == null ? "" : ` · 湿度 ${weather.humidity}%`}{weather.location ? ` · ${weather.location}` : ""}</span>
                ) : (
                  <span>天气详情仅在 App 授权后显示，网页端不猜测当前位置。</span>
                )}
              </div>
            </div>
            <div className="sync-truth cloud">
              <CloudCheck size={20} weight="fill" />
              <span><strong>云端读取已连接</strong><small>{`最后读取 ${syncTime(workspace.lastSyncedAt, timeZone)}`}</small></span>
            </div>
          </header>

          <section className="briefing-metrics" aria-label="牧场概览">
            {metrics.map(({ key, label, unit, icon: Icon }) => (
              <button
                key={key}
                type="button"
                onClick={() => onNavigate(key === "activePens" ? "pens" : key === "feedsToday" ? "feeding" : "flock")}
              >
                <Icon size={27} weight="duotone" />
                <span><small>{label}</small><strong>{workspace.metrics[key].toLocaleString("zh-CN")}<em>{unit}</em></strong></span>
                <CaretRight size={17} weight="bold" />
              </button>
            ))}
          </section>

          <section className="briefing-section alert-section">
            <div className="section-heading">
              <span><p className="eyebrow">TODAY</p><h2>待办与异常</h2></span>
            </div>
            <div className="operational-list">
              {alerts.length ? alerts.map((alert) => (
                <button className="operational-row" type="button" key={alert.id} onClick={() => onNavigate("alerts", { selectedID: alert.id })}>
                  <WarningCircle className={`tone-${alert.tone}`} size={26} weight="fill" />
                  <span className="row-copy"><strong>{alert.title}</strong><small>{alert.description}</small></span>
                  <span className="row-value">{alert.count}<small>{alert.unit}</small></span>
                  <CaretRight size={19} weight="bold" />
                </button>
              )) : (
                <div className="open-empty-state">
                  <strong>没有可展示的网页规则结果</strong>
                  <span>App 的规则计算尚未接入 Web，因此这里保持为空。</span>
                </div>
              )}
            </div>
            <button className="briefing-section-footer" type="button" onClick={() => onNavigate("alerts")}>查看全部 <CaretRight size={16} /></button>
          </section>

          <section className="briefing-section production-section">
            <div className="section-heading">
              <span><p className="eyebrow">FARM</p><h2>生产状态</h2></span>
            </div>
            <ProductionRow icon={Tag} title="羊只档案" detail="查看在场羊只、当前圈舍、体重与生产阶段" value={workspace.metrics.activeSheep} unit="只" onClick={() => onNavigate("flock")} />
            <ProductionRow icon={Barn} title="圈舍状态" detail="查看有羊圈舍、用途与实时存栏投影" value={workspace.metrics.activePens} unit="个" onClick={() => onNavigate("pens")} />
          </section>
        </section>

        <aside className="home-actions">
          <button className="new-record-button" type="button" onClick={() => onCreateRecord("new")}>
            <Plus size={21} weight="bold" />
            新建记录
          </button>

          <section className="action-section">
            <div className="side-section-title"><p className="eyebrow">QUICK ACTIONS</p><h2>快捷操作</h2></div>
            <div className="quick-operation-list">
              {quickActions.map(({ id, label, icon: Icon }) => (
                <button type="button" key={id} onClick={() => runQuickAction(id)}>
                  <Icon size={21} />
                  <span>{label}</span>
                  <CaretRight size={17} weight="bold" />
                </button>
              ))}
            </div>
          </section>

          <section className="action-section tmr-summary">
            <div className="side-section-title split-title">
              <span><p className="eyebrow">FEEDING</p><h2>今日投喂与 TMR</h2></span>
              <button type="button" onClick={() => onNavigate("tmr")}>工作台</button>
            </div>
            {tmrMeals.length ? (
              <div className="meal-summary-list">
                {tmrMeals.map((meal) => (
                  <button type="button" key={meal.id} onClick={() => onNavigate("tmr-monitor")}>
                    <span className="meal-period-badge">{meal.period}</span>
                    <time>{meal.time}</time>
                    <span className="meal-stat"><small>计划</small><strong>{meal.planKg.toLocaleString("zh-CN")}<em> kg</em></strong></span>
                    <span className={`meal-stat actual ${meal.status}`}><small>实际投喂</small><strong>{meal.actualKg.toLocaleString("zh-CN")}<em> kg</em></strong></span>
                    <CheckCircle size={18} weight="fill" className={`meal-check ${meal.status}`} />
                  </button>
                ))}
              </div>
            ) : (
              <div className="side-empty-state">云端 TMR 顿次监控尚未接入。</div>
            )}
          </section>
        </aside>
      </div>
    </main>
  );
}
