import { useEffect, useMemo, useState } from "react";
import { Baby } from "@phosphor-icons/react/Baby";
import { BowlFood } from "@phosphor-icons/react/BowlFood";
import { CaretDown } from "@phosphor-icons/react/CaretDown";
import { CaretRight } from "@phosphor-icons/react/CaretRight";
import { ChartLineUp } from "@phosphor-icons/react/ChartLineUp";
import { CheckCircle } from "@phosphor-icons/react/CheckCircle";
import { Robot } from "@phosphor-icons/react/Robot";
import { Scales } from "@phosphor-icons/react/Scales";
import { Tag } from "@phosphor-icons/react/Tag";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";
import {
  addFarmDays,
  calculateFeedIntakeAnalytics,
  calculateLambAnalytics,
  calculateReproductionAnalytics,
  calculateWeightAnalytics,
  calculateWeightTrendline,
  defaultFeedRange,
  defaultReproductionFilter,
  feedFilterOptions,
  lambFilterOptions,
  reproductionFilterOptions,
  weightFilterOptions,
} from "../../lib/appAnalytics.js";
import { PageTop, ProjectionNotice } from "./FeaturePageShared.jsx";
import FarmAssistant from "../FarmAssistant.jsx";

const reportCards = [
  { id: "weight", title: "增重分析", detail: "有效羊只、最新均重、首末 ADG 与记录日趋势", icon: Scales },
  { id: "lamb", title: "羔羊分析", detail: "完整产羔、死淘分母、断奶质量与缺失样本", icon: Baby },
  { id: "reproduction", title: "繁殖表现", detail: "固定截止日母羊群、胎间距、产后天数与品种", icon: Tag },
  { id: "intake", title: "采食营养分析", detail: "真实羊天、剩料边界、营养覆盖与生长支持", icon: BowlFood },
];

const regressionKinds = [
  ["none", "无"], ["linear", "线性"], ["logarithmic", "对数"], ["exponential", "指数"],
  ["quadratic", "二次"], ["cubic", "三次"], ["quartic", "四次"], ["quintic", "五次"], ["sextic", "六次"],
];

const stageLabels = {
  lactatingLamb: "哺乳羔羊", weanedLamb: "断奶羔羊", replacement: "后备羊", growing: "育成羊",
  fattening: "育肥羊", breedingRam: "种公羊", breedingEwe: "繁殖母羊", unknown: "未分类",
};

function numberText(value, maximumFractionDigits = 1) {
  if (value == null || !Number.isFinite(value)) return "—";
  return value.toLocaleString("zh-CN", { maximumFractionDigits, minimumFractionDigits: 0 });
}

function percentText(value, digits = 1) {
  return value == null || !Number.isFinite(value) ? "—" : `${numberText(value * 100, digits)}%`;
}

function dateText(value, timeZone) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("zh-CN", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

function monthText(value) {
  const [year, month] = String(value ?? "").split("-");
  return year && month ? `${year} 年 ${Number(month)} 月` : "—";
}

function metricValue(value, unit, digits = 1) {
  const valid = value != null && Number.isFinite(value);
  return <>{numberText(value, digits)}{valid && unit ? <em>{unit}</em> : null}</>;
}

function AnalysisMetrics({ items }) {
  return (
    <section className="analysis-metric-strip">
      {items.map((item) => (
        <article key={item.label}>
          <small>{item.label}</small>
          <strong>{metricValue(item.value, item.unit, item.digits)}</strong>
          <span>{item.sample}</span>
        </article>
      ))}
    </section>
  );
}

function AnalysisFilterBar({ children, caption }) {
  return (
    <section className="analysis-filter-shell">
      <div className="analysis-filter-bar">{children}</div>
      {caption ? <p className="analysis-scope-caption">{caption}</p> : null}
    </section>
  );
}

function SelectField({ label, value, onChange, children, disabled = false }) {
  return (
    <label className="analysis-filter-field">
      <span>{label}</span>
      <select value={value} onChange={onChange} disabled={disabled}>{children}</select>
    </label>
  );
}

function DateField({ label, value, onChange, max }) {
  return (
    <label className="analysis-filter-field date-filter-field">
      <span>{label}</span>
      <input type="date" value={value} max={max} onChange={onChange} />
    </label>
  );
}

function Segmented({ value, onChange, items, label }) {
  return (
    <div className="analysis-segmented" role="group" aria-label={label}>
      {items.map(([id, text]) => <button type="button" key={id} className={value === id ? "active" : ""} onClick={() => onChange(id)}>{text}</button>)}
    </div>
  );
}

function AnalysisNotice({ children, warning = false }) {
  const Icon = warning ? WarningCircle : CheckCircle;
  return <aside className={`analysis-inline-notice${warning ? " warning" : ""}`}><Icon size={20} weight="fill" /><span>{children}</span></aside>;
}

function BoundaryCard({ title = "App 统计边界", boundary, timeZone, children }) {
  return (
    <aside className="analysis-note analysis-boundary-card">
      <ChartLineUp size={27} />
      <h2>{title}</h2>
      <p>{children}</p>
      <dl>
        <div><dt>起始</dt><dd>{dateText(boundary?.firstAt, timeZone)}</dd></div>
        <div><dt>截止</dt><dd>{dateText(boundary?.lastAt, timeZone)}</dd></div>
        <div><dt>原始样本</dt><dd>{numberText(boundary?.sampleCount ?? 0, 0)} 条</dd></div>
      </dl>
    </aside>
  );
}

function EmptyAnalysis({ icon: Icon, title, detail }) {
  return <div className="open-empty-state page-empty"><Icon size={32} /><strong>{title}</strong><span>{detail}</span></div>;
}

function LineChart({ series, color = "#1677ff", targetRange = null, emptyText }) {
  const points = (series ?? []).filter((item) => Number.isFinite(item.value ?? item.average));
  if (!points.length) return <div className="empty-state">{emptyText}</div>;
  const values = points.map((item) => item.value ?? item.average);
  if (targetRange) values.push(targetRange[0], targetRange[1]);
  let minimum = Math.min(...values);
  let maximum = Math.max(...values);
  if (minimum === maximum) { minimum -= 1; maximum += 1; }
  const padding = Math.max((maximum - minimum) * 0.08, 0.001);
  minimum -= padding;
  maximum += padding;
  const width = 900;
  const height = 250;
  const left = 58;
  const right = 20;
  const top = 18;
  const bottom = 36;
  const x = (index) => left + (width - left - right) * (points.length === 1 ? 0.5 : index / (points.length - 1));
  const y = (value) => top + (height - top - bottom) * (maximum - value) / (maximum - minimum);
  const path = points.map((point, index) => `${index ? "L" : "M"}${x(index).toFixed(1)},${y(point.value ?? point.average).toFixed(1)}`).join(" ");
  const firstLabel = points[0].date ?? points[0].month;
  const lastLabel = points.at(-1).date ?? points.at(-1).month;
  return (
    <svg className="analysis-svg-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="分析趋势图">
      {targetRange ? <rect className="chart-target-band" x={left} y={y(targetRange[1])} width={width - left - right} height={Math.max(1, y(targetRange[0]) - y(targetRange[1]))} /> : null}
      {[0, 1, 2, 3].map((index) => {
        const value = minimum + (maximum - minimum) * index / 3;
        return <g key={index}><line className="chart-grid-line" x1={left} x2={width - right} y1={y(value)} y2={y(value)} /><text x={left - 9} y={y(value) + 4} textAnchor="end">{numberText(value, 1)}</text></g>;
      })}
      <path className="chart-area" d={`${path} L${x(points.length - 1)},${height - bottom} L${x(0)},${height - bottom} Z`} style={{ fill: color }} />
      <path className="chart-main-line" d={path} style={{ stroke: color }} />
      {points.map((point, index) => <circle key={`${point.date ?? point.month}-${index}`} cx={x(index)} cy={y(point.value ?? point.average)} r="3.4" style={{ fill: color }}><title>{point.date ?? point.month}：{numberText(point.value ?? point.average, 2)}（n={point.sampleCount ?? point.count ?? "—"}）</title></circle>)}
      <text className="chart-axis-label" x={left} y={height - 8}>{firstLabel}</text>
      <text className="chart-axis-label" x={width - right} y={height - 8} textAnchor="end">{lastLabel}</text>
    </svg>
  );
}

function ScatterChart({ points, trend }) {
  const scatter = (points ?? []).filter((item) => Number.isFinite(item.baselineWeight) && Number.isFinite(item.adg));
  if (!scatter.length) return <div className="empty-state">没有两次以上且日期有效的相邻称重配对。</div>;
  const trendPoints = (trend ?? []).filter((item) => Number.isFinite(item.x) && Number.isFinite(item.y));
  const xs = [...scatter.map((item) => item.baselineWeight), ...trendPoints.map((item) => item.x)];
  const ys = [...scatter.map((item) => item.adg), ...trendPoints.map((item) => item.y)];
  let minX = Math.min(...xs); let maxX = Math.max(...xs); let minY = Math.min(...ys); let maxY = Math.max(...ys);
  if (minX === maxX) { minX -= 1; maxX += 1; }
  if (minY === maxY) { minY -= 0.01; maxY += 0.01; }
  const width = 900; const height = 250; const left = 58; const right = 20; const top = 18; const bottom = 40;
  const x = (value) => left + (width - left - right) * (value - minX) / (maxX - minX);
  const y = (value) => top + (height - top - bottom) * (maxY - value) / (maxY - minY);
  const trendPath = trendPoints.map((point, index) => `${index ? "L" : "M"}${x(point.x).toFixed(1)},${y(point.y).toFixed(1)}`).join(" ");
  return (
    <svg className="analysis-svg-chart scatter-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="前次体重与区间日增重散点图">
      {[0, 1, 2, 3].map((index) => <line key={index} className="chart-grid-line" x1={left} x2={width - right} y1={top + (height - top - bottom) * index / 3} y2={top + (height - top - bottom) * index / 3} />)}
      {scatter.map((point, index) => <circle key={`${point.sheepID}-${point.date}-${index}`} cx={x(point.baselineWeight)} cy={y(point.adg)} r="4" className="scatter-dot"><title>前次体重 {numberText(point.baselineWeight, 1)} kg · ADG {numberText(point.adg, 3)} kg/天</title></circle>)}
      {trendPath ? <path className="chart-regression-line" d={trendPath} /> : null}
      <text className="chart-axis-label" x={left} y={height - 9}>前次体重 {numberText(minX, 1)} kg</text>
      <text className="chart-axis-label" x={width - right} y={height - 9} textAnchor="end">{numberText(maxX, 1)} kg</text>
    </svg>
  );
}

function WeightAnalysis({ source, now, timeZone }) {
  const options = useMemo(() => weightFilterOptions(source, { now, timeZone }), [source, now, timeZone]);
  const [scope, setScope] = useState("all");
  const [penID, setPenID] = useState("");
  const [batchID, setBatchID] = useState("");
  const [regression, setRegression] = useState("linear");
  useEffect(() => { if (penID && !options.pens.some((pen) => String(pen.id) === penID)) setPenID(""); }, [options.pens, penID]);
  useEffect(() => { if (batchID && !options.batches.some((batch) => String(batch.id) === batchID)) setBatchID(""); }, [options.batches, batchID]);
  const data = useMemo(() => calculateWeightAnalytics(source, { scope, penID: penID || null, batchID: batchID || null, cutoff: options.cutoff, now, timeZone }), [source, scope, penID, batchID, options.cutoff, now, timeZone]);
  const trendline = useMemo(() => calculateWeightTrendline(data.scatter, regression), [data.scatter, regression]);
  return (
    <>
      <AnalysisFilterBar caption={`体重分析截止 ${dateText(data.cutoff, timeZone)}；截止日取 App 可见普通称重的最晚发生时间。选择批次后，样本还必须在每条体重发生时属于该批次。`}>
        <SelectField label="样本范围" value={scope} onChange={(event) => setScope(event.target.value)}><option value="all">全部</option><option value="inHerdOnly">仅在群</option><option value="removedOnly">仅离群</option></SelectField>
        <SelectField label="圈舍" value={penID} onChange={(event) => setPenID(event.target.value)} disabled={Boolean(batchID)}><option value="">全场</option>{options.pens.map((pen) => <option value={pen.id} key={pen.id}>{pen.name}</option>)}</SelectField>
        <SelectField label="生产批次" value={batchID} onChange={(event) => setBatchID(event.target.value)}><option value="">不按批次</option>{options.batches.map((batch) => <option value={batch.id} key={batch.id}>{batch.name}</option>)}</SelectField>
      </AnalysisFilterBar>
      <AnalysisMetrics items={[
        { label: "有效羊只", value: data.sheepIDs.length, unit: "只", digits: 0, sample: `有体重样本 ${numberText(data.sheepSampleCount, 0)} 只` },
        { label: "最新均重", value: data.latestAverageWeight, unit: "千克", sample: `每只羊最新值 n=${numberText(data.latestAverageWeightSampleCount, 0)}` },
        { label: "首末 ADG", value: data.latestAverageADG, unit: "千克/天", digits: 3, sample: `首末有效配对 n=${numberText(data.latestAverageADGSampleCount, 0)}` },
      ]} />
      {!data.canonicalSampleCount ? <EmptyAnalysis icon={Scales} title="当前筛选没有可计算体重" detail="需要普通称重、断奶重或有效出生重；网页不会补入演示曲线。" /> : (
        <>
          <div className="analysis-layout">
            <section className="workspace-panel flat-panel"><div className="panel-heading"><h2>平均体重趋势</h2><span>每个记录日期的样本平均体重</span></div><LineChart series={data.weightTrend} emptyText="当前筛选没有体重趋势。" /></section>
            <BoundaryCard boundary={data.boundary} timeZone={timeZone}>同一羊只同一天按 App 优先级只保留一条：普通称重、断奶重、产羔出生重、断奶记录出生重。圈舍按截止日归属；离群按截止日前离场事件判断。</BoundaryCard>
          </div>
          <section className="workspace-panel flat-panel analysis-secondary-panel"><div className="panel-heading"><h2>区间 ADG 趋势</h2><span>相邻两次有效体重的平均日增重</span></div><LineChart series={data.adgTrend} color="#f08c2e" emptyText="没有两次以上且日期有效的相邻称重配对。" /></section>
          <section className="workspace-panel flat-panel analysis-secondary-panel"><div className="panel-heading"><div><h2>体重与 ADG</h2><span>前次体重与区间日增重的关系</span></div><SelectField label="趋势线" value={regression} onChange={(event) => setRegression(event.target.value)}>{regressionKinds.map(([id, text]) => <option value={id} key={id}>{text}</option>)}</SelectField></div><ScatterChart points={data.scatter} trend={trendline} /></section>
        </>
      )}
    </>
  );
}

function LambAnalysis({ source, timeZone }) {
  const years = useMemo(() => lambFilterOptions(source, timeZone), [source, timeZone]);
  const [year, setYear] = useState("全部");
  const [section, setSection] = useState("lambing");
  const data = useMemo(() => calculateLambAnalytics(source, { selectedYear: year === "全部" ? null : year, selectedWeaningMonth: "全部", timeZone }), [source, year, timeZone]);
  const lamb = data.lambStats;
  const weaning = data.weaning;
  return (
    <>
      <Segmented label="羔羊分析内容" value={section} onChange={setSection} items={[["lambing", "产羔分析"], ["weaning", "断奶分析"]]} />
      <AnalysisFilterBar caption="年份同时约束产羔发生日和断奶发生日；默认“全部”与 App 一致。"><SelectField label="年份" value={year} onChange={(event) => setYear(event.target.value)}><option value="全部">全部</option>{years.map((item) => <option value={item} key={item}>{item} 年</option>)}</SelectField></AnalysisFilterBar>
      {section === "lambing" ? (
        <>
          {data.incompleteLambingCount > 0 ? <AnalysisNotice warning>有 {data.incompleteLambingCount} 胎缺少胎次、死胎数或逐只羔羊明细，未纳入需要完整字段的指标。</AnalysisNotice> : null}
          <AnalysisMetrics items={[
            { label: "产羔总数", value: lamb.totalLambs, unit: "只", digits: 0, sample: `完整产羔 ${numberText(data.completeLambingCount, 0)}/${numberText(data.allLambingCount, 0)} 胎` },
            { label: "出生死亡率", value: lamb.totalLambs ? lamb.mortalityRate * 100 : null, unit: "%", sample: `死羔 ${numberText(data.deadBorn, 0)} / 总羔 ${numberText(lamb.totalLambs, 0)}` },
            { label: "死淘/消失率", value: lamb.totalLambs > data.deadBorn ? lamb.deathCullRate * 100 : null, unit: "%", sample: "分母为完整记录中的活羔" },
          ]} />
          <section className="workspace-panel flat-panel analysis-secondary-panel"><div className="panel-heading"><h2>月度产羔</h2><span>完整记录；公母、出生重和断奶 ADG 分开统计</span></div>{lamb.months.length ? <div className="analysis-month-cards">{lamb.months.map((month) => <article key={month.month}><header><span><strong>{monthText(month.month)}</strong><small>{month.totalDams} 胎 · {month.totalLambs} 羔 · 公/母 {month.maleLambs}/{month.femaleLambs} · 死胎 {month.birthDead}</small></span><b>胎均 {numberText(month.avgPerLamb, 2)}</b></header><div className="sex-metric-lines"><p><i className="male-dot">公</i>初生 {month.maleWeightCount ? `${numberText(month.maleWeightAverage, 2)} kg（n=${month.maleWeightCount}）` : "—"} · ADG {month.maleADGCount ? `${numberText(month.maleADGAverage, 0)} g/天（n=${month.maleADGCount}）` : "—"}</p><p><i className="female-dot">母</i>初生 {month.femaleWeightCount ? `${numberText(month.femaleWeightAverage, 2)} kg（n=${month.femaleWeightCount}）` : "—"} · ADG {month.femaleADGCount ? `${numberText(month.femaleADGAverage, 0)} g/天（n=${month.femaleADGCount}）` : "—"}</p></div></article>)}</div> : <div className="empty-state">当前筛选没有完整的产羔记录。</div>}</section>
        </>
      ) : (
        <>
          <AnalysisMetrics items={[
            { label: "断奶记录", value: weaning.total, unit: "条", digits: 0, sample: "按断奶发生月统计" },
            { label: "异常记录", value: weaning.abnormalCount, unit: "条", digits: 0, sample: "性别、年龄、断奶重或 ADG 缺失" },
            { label: "平均 ADG", value: weaning.adgCount ? weaning.averageADG : null, unit: "克/天", digits: 0, sample: `有效起算称重 n=${numberText(weaning.adgCount, 0)}` },
          ]} />
          <AnalysisNotice>断奶 ADG 只使用出生后且早于断奶时间的最早一条普通称重作起点；断奶重没有高于起算体重时不计算。</AnalysisNotice>
          <section className="workspace-panel flat-panel analysis-secondary-panel"><div className="panel-heading"><h2>月度断奶</h2><span>每个均值都保留独立有效样本数</span></div>{weaning.months.length ? <div className="analysis-month-cards">{weaning.months.map((month) => <article key={month.month}><header><span><strong>{monthText(month.month)}</strong><small>{month.totalCount} 条 · 公/母 {month.maleCount}/{month.femaleCount} · 异常 {month.abnormalCount}</small></span><b>平均 {month.weightCount ? `${numberText(month.averageWeight, 1)} kg` : "—"}</b></header><div className="sex-metric-lines"><p><i className="male-dot">公</i>断奶 {month.maleWeightCount ? `${numberText(month.maleAverageWeight, 1)} kg（n=${month.maleWeightCount}）` : "—"} · ADG {month.maleADGCount ? `${numberText(month.maleAverageADG, 0)} g/天（n=${month.maleADGCount}）` : "—"}</p><p><i className="female-dot">母</i>断奶 {month.femaleWeightCount ? `${numberText(month.femaleAverageWeight, 1)} kg（n=${month.femaleWeightCount}）` : "—"} · ADG {month.femaleADGCount ? `${numberText(month.femaleAverageADG, 0)} g/天（n=${month.femaleADGCount}）` : "—"}</p></div></article>)}</div> : <div className="empty-state">当前筛选没有断奶记录。</div>}</section>
        </>
      )}
      <BoundaryCard boundary={data.boundary} timeZone={timeZone}>完整产羔要求胎次、死羔数、总羔数和逐只明细互相一致。断奶年龄按牧场时区的自然日计算；无有效样本显示“—”。</BoundaryCard>
    </>
  );
}

function ReproductionAnalysis({ source, now, timeZone }) {
  const initial = useMemo(() => defaultReproductionFilter({ now, timeZone }), [now, timeZone]);
  const [filter, setFilter] = useState(initial);
  const [section, setSection] = useState("interval");
  useEffect(() => setFilter(initial), [initial]);
  const options = useMemo(() => reproductionFilterOptions(source, { endDate: filter.endDate, now, timeZone }), [source, filter.endDate, now, timeZone]);
  const data = useMemo(() => calculateReproductionAnalytics(source, { filter, now, timeZone }), [source, filter, now, timeZone]);
  const penValue = filter.penScope === "pen" ? `pen:${filter.penID ?? ""}` : filter.penScope;
  function changePen(value) {
    if (value.startsWith("pen:")) setFilter((current) => ({ ...current, penScope: "pen", penID: value.slice(4) }));
    else setFilter((current) => ({ ...current, penScope: value, penID: null }));
  }
  return (
    <>
      <AnalysisFilterBar caption={`截止 ${filter.endDate} 固定查询母羊群：${numberText(data.cohortCount, 0)} 只。开始日和结束日都包含整天；区间前的产羔仍作为胎间距和产后天数的前序依据。`}>
        <DateField label="开始日" value={filter.startDate} max={filter.endDate} onChange={(event) => setFilter((current) => ({ ...current, startDate: event.target.value }))} />
        <DateField label="结束日" value={filter.endDate} max={initial.endDate} onChange={(event) => setFilter((current) => ({ ...current, endDate: event.target.value }))} />
        <SelectField label="羊舍" value={penValue} onChange={(event) => changePen(event.target.value)}><option value="all">全部羊舍</option>{options.pens.map((pen) => <option value={`pen:${pen.id}`} key={pen.id}>{pen.name}</option>)}{options.includesUnassigned ? <option value="unassigned">未分配羊舍</option> : null}</SelectField>
        <SelectField label="品种" value={filter.breed ?? ""} onChange={(event) => setFilter((current) => ({ ...current, breed: event.target.value || null }))}><option value="">全部品种</option>{options.breeds.map((breed) => <option value={breed} key={breed}>{breed}</option>)}</SelectField>
      </AnalysisFilterBar>
      {data.incompleteLambingCount > 0 ? <AnalysisNotice warning>有 {data.incompleteLambingCount} 胎字段不完整，仅不纳入需要完整字段的指标；胎间距和产后天数仍按真实产羔日期计算。</AnalysisNotice> : null}
      <AnalysisMetrics items={[
        { label: "平均每胎", value: data.completeLambingCount ? data.overview.averageTotal : null, unit: "羔", sample: `完整产羔 n=${numberText(data.completeLambingCount, 0)}` },
        { label: "死亡率", value: data.completeLambingCount ? data.overview.mortalityRate * 100 : null, unit: "%", sample: "死羔数 / 完整记录总羔数" },
        { label: "平均初生重", value: data.completeLambingCount && data.overview.averageBirthWeight > 0 ? data.overview.averageBirthWeight : null, unit: "千克", sample: "只纳入正值出生重" },
      ]} />
      <Segmented label="繁殖分析维度" value={section} onChange={setSection} items={[["interval", "胎间距"], ["postpartum", "产后天数"], ["breed", "品种分析"]]} />
      {section === "interval" ? (
        <div className="analysis-layout">
          <section className="workspace-panel flat-panel"><div className="panel-heading"><h2>胎间距趋势</h2><span>固定截止日母羊群；绿色为 150–240 天</span></div><LineChart series={data.intervalPoints} targetRange={[150, 240]} emptyText="当前切片没有母羊具备两次有效产羔日期。" /></section>
          <section className="workspace-panel flat-panel compact-result-panel"><div className="panel-heading"><h2>胎间距合格率</h2><span>每月取最接近 15 日的群体截面</span></div>{data.qualifiedRates.length ? <div className="compact-analysis-list">{data.qualifiedRates.slice().reverse().map((item) => <article key={item.month}><time>{monthText(item.month)}</time><strong>{numberText(item.qualified, 1)}% 合格</strong><span>不合格 {numberText(item.unqualified, 1)}% · n={item.sampleCount}</span></article>)}</div> : <div className="empty-state">当前切片的胎间距数据不足。</div>}</section>
        </div>
      ) : null}
      {section === "postpartum" ? <section className="workspace-panel flat-panel analysis-secondary-panel"><div className="panel-heading"><h2>产后天数趋势</h2><span>每个采样日距各母羊最近一次产羔的自然日数</span></div><LineChart series={data.postpartumPoints} color="#f08c2e" emptyText="当前切片没有具备产羔日期的母羊。" /></section> : null}
      {section === "breed" ? <section className="workspace-panel flat-panel analysis-secondary-panel"><div className="panel-heading"><h2>品种分析</h2><span>当前日期、羊舍与品种切片</span></div>{data.breedRows.length ? <div className="rank-list analysis-rank-list">{data.breedRows.map((row, index) => <article key={row.breed}><b>{index + 1}</b><span><strong>{row.breed}</strong><small>{row.sheepCount} 只 · {row.lambingCount} 胎</small></span><em>胎均 {numberText(row.averageLambs, 2)}</em></article>)}</div> : <div className="empty-state">当前切片的品种样本不足。</div>}</section> : null}
      <section className="workspace-panel flat-panel analysis-secondary-panel"><div className="panel-heading"><h2>月度产羔</h2><span>所选区间内完整产羔</span></div>{data.monthly.length ? <div className="compact-analysis-list">{data.monthly.slice().reverse().map((item) => <article key={item.month}><time>{monthText(item.month)}</time><strong>{item.lambings} 胎 · {item.total} 羔</strong><span>公/母 {item.male}/{item.female}</span></article>)}</div> : <div className="empty-state">当前筛选范围没有完整繁殖记录。</div>}</section>
      <BoundaryCard boundary={data.boundary} timeZone={timeZone}>母羊群固定在结束日：必须为母羊、结束日前已入场、结束日仍在群，并按该日历史圈舍和当前品种筛选。胎间距只取 0–999 天的有效相邻产羔。</BoundaryCard>
    </>
  );
}

function feedEvidenceLabel(pen) {
  if (pen.conflicts.length) return "数据冲突";
  if (pen.incompleteIntervalCount > 0) return "部分未闭合";
  if (pen.evidence.has("measured") && pen.evidence.has("estimated")) return "实测+估算";
  if (pen.evidence.has("estimated")) return "估算";
  if (pen.evidence.has("historicalHeadCount")) return "历史头数估算";
  return "实测";
}

function growthText(growth) {
  const value = growth.calibratedExpectedADGKg ?? growth.nutritionPotentialADGKg;
  if (value != null) return `${numberText(value * 1_000, 0)} g/天`;
  if (["breedingEwe", "breedingRam"].includes(growth.stage)) return "维持差额";
  return "数据不足";
}

function PenMultiSelect({ pens, selection, onChange }) {
  return (
    <details className="pen-multiselect">
      <summary>圈舍：{selection.length ? `已选 ${selection.length} 个` : "全部"}<CaretDown size={15} /></summary>
      <div>{pens.length ? pens.map((pen) => <label key={pen.id}><input type="checkbox" checked={selection.includes(String(pen.id))} onChange={(event) => onChange(event.target.checked ? [...selection, String(pen.id)] : selection.filter((id) => id !== String(pen.id)))} />{pen.name}</label>) : <span>该时间段没有有羊天的圈舍</span>}</div>
    </details>
  );
}

function FeedPenCard({ pen }) {
  return (
    <details className="feed-analysis-pen-card">
      <summary>
        <span><strong>{pen.name}</strong><small className={pen.conflicts.length || pen.incompleteIntervalCount ? "warning-text" : ""}>{feedEvidenceLabel(pen)}</small></span>
        <span className="feed-pen-summary-grid"><i>鲜重<b>{numberText(pen.freshKilograms, 1)} kg</b></i><i>DMI<b>{numberText(pen.nutrition.dryMatterKilogramsPerSheepDay, 2)} kg/羊天</b></i><i>ME<b>{numberText(pen.nutrition.meMJPerSheepDay, 1)} MJ/羊天</b></i><i>支持日增重<b>{growthText(pen.growth)}</b></i></span>
        <CaretDown size={18} />
      </summary>
      <div className="feed-pen-detail">
        <section><h3>采食概览</h3><dl className="feed-detail-grid"><div><dt>真实投喂羊天</dt><dd>{numberText(pen.sheepDays, 1)}</dd></div><div><dt>每只每天鲜重</dt><dd>{numberText(pen.nutrition.freshKilogramsPerSheepDay, 2)} kg</dd></div><div><dt>每只每天 DMI</dt><dd>{numberText(pen.nutrition.dryMatterKilogramsPerSheepDay, 2)} kg</dd></div><div><dt>完整 / 未闭合区间</dt><dd>{pen.completeIntervalCount} / {pen.incompleteIntervalCount}</dd></div></dl></section>
        <section><h3>原料组成</h3>{pen.ingredients.length ? <div className="feed-ingredient-list">{pen.ingredients.map((ingredient) => <p key={ingredient.id}><strong>{ingredient.name}</strong><span>全舍 {numberText(ingredient.freshKilograms, 1)} kg · {numberText(ingredient.freshKilogramsPerSheepDay, 3)} kg/羊天</span></p>)}</div> : <p className="muted-copy">没有可归因原料。</p>}</section>
        <section><h3>营养供应（每只每天）</h3><dl className="feed-detail-grid"><div><dt>ME</dt><dd>{numberText(pen.nutrition.meMJPerSheepDay, 1)} MJ</dd></div><div><dt>CP</dt><dd>{numberText(pen.nutrition.crudeProteinGramsPerSheepDay, 0)} g</dd></div><div><dt>MP</dt><dd>{numberText(pen.nutrition.metabolizableProteinGramsPerSheepDay, 0)} g</dd></div><div><dt>NDF / ADF</dt><dd>{numberText(pen.nutrition.ndfGramsPerSheepDay, 0)} / {numberText(pen.nutrition.adfGramsPerSheepDay, 0)} g</dd></div></dl>{pen.nutrition.mpEstimated ? <p className="detail-warning">MP：仅有 CP 时采用 Plus 兼容估算模型。</p> : pen.nutrition.mpBlockedReason ? <p className="detail-warning">MP 未计算：{pen.nutrition.mpBlockedReason}</p> : null}</section>
        <section><h3>生长支持</h3><dl className="feed-detail-grid"><div><dt>阶段 / 占比</dt><dd>{stageLabels[pen.growth.stage] ?? "数据不足"} · {percentText(pen.growth.dominantStageRatio)}</dd></div><div><dt>平均体重</dt><dd>{numberText(pen.growth.averageWeightKilograms, 1)} kg</dd></div><div><dt>营养支持 ADG</dt><dd>{pen.growth.nutritionPotentialADGKg == null ? "—" : `${numberText(pen.growth.nutritionPotentialADGKg * 1_000, 0)} g/天`}</dd></div><div><dt>校准预期 ADG</dt><dd>{pen.growth.calibratedExpectedADGKg == null ? "—" : `${numberText(pen.growth.calibratedExpectedADGKg * 1_000, 0)} g/天`}</dd></div></dl>{pen.growth.limitingFactor ? <p className="muted-copy">限制因素：{pen.growth.limitingFactor}</p> : null}{pen.growth.blockedReason ? <p className="detail-warning">停止预测：{pen.growth.blockedReason}</p> : null}</section>
        <section><h3>每日趋势</h3>{pen.dailyTrend.length ? <div className="compact-analysis-list">{pen.dailyTrend.map((day) => <article key={day.date}><time>{day.date}</time><strong>鲜重 {numberText(day.freshKilograms, 1)} kg · 羊天 {numberText(day.sheepDays, 1)}</strong><span>DMI {numberText(day.dmiKilogramsPerSheepDay, 2)} kg/羊天 · ME {numberText(day.meMJPerSheepDay, 1)} MJ/羊天</span></article>)}</div> : <p className="muted-copy">没有完整每日趋势。</p>}</section>
        <section><h3>数据依据</h3><p className="muted-copy">{[...pen.evidence].sort().join(" · ") || "无测量证据"}</p>{pen.conflicts.map((conflict) => <p className="detail-warning" key={conflict}>{conflict}</p>)}</section>
      </div>
    </details>
  );
}

function FeedAnalysis({ source, now, timeZone }) {
  const initialRange = useMemo(() => defaultFeedRange({ now, timeZone, days: 7 }), [now, timeZone]);
  const [preset, setPreset] = useState("7");
  const [customStart, setCustomStart] = useState(initialRange.startDate);
  const [customEnd, setCustomEnd] = useState(initialRange.inclusiveEndDate);
  const [selectedPens, setSelectedPens] = useState([]);
  useEffect(() => { setCustomStart(initialRange.startDate); setCustomEnd(initialRange.inclusiveEndDate); }, [initialRange]);
  const range = useMemo(() => {
    if (preset === "custom") return { startDate: customStart, endDateExclusive: addFarmDays(customEnd, 1), inclusiveEndDate: customEnd };
    return defaultFeedRange({ now, timeZone, days: Number(preset) });
  }, [preset, customStart, customEnd, now, timeZone]);
  const eligiblePens = useMemo(() => feedFilterOptions(source, { ...range, now, timeZone }), [source, range, now, timeZone]);
  useEffect(() => setSelectedPens((current) => current.filter((id) => eligiblePens.some((pen) => String(pen.id) === id))), [eligiblePens]);
  const data = useMemo(() => calculateFeedIntakeAnalytics(source, { ...range, selectedPenIDs: selectedPens, now, timeZone }), [source, range, selectedPens, now, timeZone]);
  return (
    <>
      <Segmented label="采食分析时间范围" value={preset} onChange={setPreset} items={[["7", "近 7 天"], ["30", "近 30 天"], ["custom", "自定义"]]} />
      <AnalysisFilterBar caption={`正式日均只计算 ${data.startDate} 至 ${data.inclusiveEndDate} 的完整自然日，今天不混入；晚补转群、离场、投喂或盘槽记录后按事实时间重算。`}>
        {preset === "custom" ? <><DateField label="开始日" value={customStart} max={customEnd} onChange={(event) => setCustomStart(event.target.value)} /><DateField label="结束日" value={customEnd} max={initialRange.inclusiveEndDate} onChange={(event) => setCustomEnd(event.target.value)} /></> : null}
        <PenMultiSelect pens={eligiblePens} selection={selectedPens} onChange={setSelectedPens} />
      </AnalysisFilterBar>
      <AnalysisMetrics items={[
        { label: "真实投喂羊天", value: data.overview.feedingSheepDays, unit: "羊天", sample: `${data.startDate}—${data.inclusiveEndDate}` },
        { label: "有效圈舍", value: data.overview.effectivePenCount, unit: "个", digits: 0, sample: `期间投喂 ${numberText(data.recordCount, 0)} 次` },
        { label: "记录完整率", value: data.overview.recordCompleteness * 100, unit: "%", sample: "完整区间 / 全部可识别区间" },
        { label: "实测 / 估算", value: data.overview.measuredRatio * 100, unit: "% 实测", sample: `估算 ${numberText(data.overview.estimatedRatio * 100, 1)}%` },
      ]} />
      {data.overview.conflictCount > 0 ? <AnalysisNotice warning>存在 {data.overview.conflictCount} 个数据冲突；相关区间没有参与营养预测。</AnalysisNotice> : null}
      <section className="workspace-panel flat-panel analysis-secondary-panel"><div className="panel-heading"><h2>逐舍采食与营养</h2><span>自由采食需要两个盘槽边界；旧记录会明确标为估算</span></div>{data.pens.length ? <div className="feed-analysis-list">{data.pens.map((pen) => <FeedPenCard key={pen.id} pen={pen} />)}</div> : <div className="empty-state">分析期间没有可计算采食。自由采食需要两个盘槽边界；限量投喂需有有效投喂区间。</div>}</section>
      <section className="analysis-today-card"><BowlFood size={25} /><span><strong>今日（进行中）</strong><small>已记录投喂 {numberText(data.todayFeedCount, 0)} 次 · 已投料 {numberText(data.todayKilograms, 1)} kg</small></span><p>今天尚未结束，不混入正式日均；盘槽闭合后在下一完整日体现。</p></section>
      <BoundaryCard title="采食口径" boundary={data.boundary} timeZone={timeZone}>限量投喂按餐次窗口扣除盘槽剩料；自由采食必须有相邻盘槽边界。羊天由入场、转群、离场事实时间积分，只有缺身份证据时才回退历史头数。</BoundaryCard>
    </>
  );
}

export default function InsightsPage({ workspace, mode = "insights", onNavigate }) {
  const [view, setView] = useState("overview");
  const isCloud = workspace.mode === "cloud";
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const source = workspace.analyticsSource ?? {};
  const now = useMemo(() => new Date(), [workspace.farm?.id, workspace.lastSyncedAt]);
  const currentView = reportCards.find((card) => card.id === view);
  const data = workspace.insightData ?? {};
  if (mode === "assistant") return <FarmAssistant workspace={workspace} onBack={() => onNavigate("insights")} />;
  if (currentView) {
    return (
      <main className="page feature-page analysis-page">
        <PageTop title={currentView.title} description={currentView.detail} />
        <button className="text-button back-link standalone-back" type="button" onClick={() => setView("overview")}>返回洞察总览</button>
        {isCloud ? <ProjectionNotice>结果直接使用云端 App 实体，采用与 iOS 相同的事件时间、自然日、固定群体、完整样本和营养覆盖规则。</ProjectionNotice> : <ProjectionNotice>当前为演示工作区；没有真实实体时不生成牧场结论。</ProjectionNotice>}
        {view === "weight" ? <WeightAnalysis source={source} now={now} timeZone={timeZone} /> : null}
        {view === "lamb" ? <LambAnalysis source={source} timeZone={timeZone} /> : null}
        {view === "reproduction" ? <ReproductionAnalysis source={source} now={now} timeZone={timeZone} /> : null}
        {view === "intake" ? <FeedAnalysis source={source} now={now} timeZone={timeZone} /> : null}
      </main>
    );
  }
  const overviewStats = [
    { label: "统一体重样本", value: data.weight?.canonicalSampleCount ?? 0, unit: "条", icon: Scales },
    { label: "完整产羔", value: data.lamb?.completeLambingCount ?? 0, unit: "胎", icon: Baby },
    { label: "截止日母羊群", value: data.reproduction?.cohortCount ?? 0, unit: "只", icon: Tag },
    { label: "近 7 天有效采食圈舍", value: data.feed?.overview?.effectivePenCount ?? 0, unit: "个", icon: BowlFood },
  ];
  return (
    <main className="page feature-page">
      <PageTop title="洞察" description="与 App 共用统计边界：同一事件语义、时间范围、群体切片、有效样本和比例分母。" />
      {isCloud ? <ProjectionNotice>体重、产羔、断奶、繁殖、转群、离场、批次、投喂、原料营养与盘槽记录均已进入分析投影；缺失值保留为“—”。</ProjectionNotice> : null}
      <section className="insight-overview-strip insight-overview-four">{overviewStats.map(({ label, value, unit, icon: Icon }) => <article key={label}><Icon size={25} /><span><small>{label}</small><strong>{numberText(value, 0)}<em>{unit}</em></strong></span></article>)}</section>
      <section className="insight-destination-grid">
        {reportCards.map(({ id, title, detail, icon: Icon }) => <button type="button" key={id} onClick={() => setView(id)}><Icon size={28} /><span><strong>{title}</strong><small>{detail}</small></span><CaretRight size={19} weight="bold" /></button>)}
        <button className="assistant-entry" type="button" onClick={() => onNavigate("assistant")}><Robot size={28} /><span><strong>Codex 牧场助手</strong><small>MiMo 双模型 · App 同口径工具 · 图片理解</small></span><CaretRight size={19} weight="bold" /></button>
      </section>
      <section className="insight-principle"><ChartLineUp size={25} /><span><strong>所有比例显示分母，所有均值保留有效样本</strong><small>体重按事件日归并；繁殖固定截止日母羊群；采食只用完整自然日和真实盘槽边界。</small></span></section>
    </main>
  );
}
