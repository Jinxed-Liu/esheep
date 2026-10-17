import ReproductionAssociationEditor from "./ReproductionAssociationEditor.jsx";
import { useMemo, useState } from "react";
import { buildSheepGrowth } from "../../lib/sheepGrowth.js";
import { isPreBreedingLamb } from "../../lib/reproductionManagement.js";
import { resolveReproductionState } from "../../lib/reproductionCycles.js";
import { zonedStartOfDay } from "../../lib/appAnalytics.js";
import { farmDateText } from "../../lib/eventExport.js";
import "./SheepProductionDetail.css";

const sourceNames = { weighing: "称重", weaning: "断奶重", lambingBirth: "初生重", weaningBirth: "初生重" };
const number = (value, digits = 0) => value == null ? "—" : Number(value).toLocaleString("zh-CN", { minimumFractionDigits: digits, maximumFractionDigits: digits });

export default function SheepProductionDetail({ workspace, sheep, onCreateRecord, onReproductionSubmit }) {
  const raw = workspace.models?.SheepRecord?.find(s => s.id === sheep.id);
  const timeZone = workspace.farm.timeZoneIdentifier || "Asia/Shanghai";
  const asOf = workspace.lastSyncedAt ? new Date(workspace.lastSyncedAt).getTime() : Date.now();
  const [range, setRange] = useState("half"), [from, setFrom] = useState(""), [to, setTo] = useState(""), [selectedID, setSelectedID] = useState(null), [markerID,setMarkerID] = useState(null);
  const cycle = useMemo(() => raw?.sexRawValue === "ewe" ? workspace.reproductionStates?.[sheep.id] ?? resolveReproductionState(sheep.id, workspace.models?.ReproductionRecord ?? [], asOf) : null,
    [raw, workspace.reproductionStates, workspace.models, sheep.id, asOf]);
  const today = farmDateText(asOf, timeZone, false);
  const start = range === "all" ? null : range === "custom" ? from || null : (() => { return addMonths(today,range === "quarter" ? -3 : -6); })();
  const end = range === "custom" ? to || today : today;
  const growth = useMemo(() => buildSheepGrowth(workspace.analyticsSource ?? {}, sheep.id, { timeZone, asOf, dateFrom: start, dateTo: end }), [workspace.analyticsSource, sheep.id, timeZone, asOf, start, end]);
  const selected = growth.intervals.find(r => r.id === selectedID || r.start.id === selectedID) ?? growth.intervals.at(-1);
  const present = raw?.statusRawValue === "active" && !raw?.isHistoricalArchive;
  const facts = useMemo(() => (workspace.models?.ReproductionRecord ?? []).filter(r => r.eweID === sheep.id && r.deletedAt == null).sort((a, b) => b.occurredAt - a.occurredAt), [workspace.models, sheep.id]);
  const dayDifference = value => Math.round((Date.parse(`${today}T00:00:00Z`) - Date.parse(`${farmDateText(value, timeZone, false)}T00:00:00Z`)) / 86400000);
  const markers = useMemo(() => (workspace.events??[]).filter(e => e.relatedSheepIDs?.includes(sheep.id) && (e.type==="transfer" || e.label==="用途变更") && (!start || farmDateText(e.at,timeZone,false)>=start) && farmDateText(e.at,timeZone,false)<=end), [workspace.events,sheep.id,start,end,timeZone]);
  const chartDomain = growth.points.length ? [start ? zonedStartOfDay(start,timeZone).getTime() : new Date(growth.points[0].at).getTime(), zonedStartOfDay(end,timeZone).getTime()+86400000-1] : null;
  const weighingDays = workspace.reproductionSettings?.weighingReminderDays;
  const settings = workspace.reproductionSettings ?? {};
  const preBreedingLamb = raw?.sexRawValue === "ewe" && isPreBreedingLamb(raw, facts, settings, timeZone, asOf);
  const birthDay = raw?.birthAt == null ? null : farmDateText(raw.birthAt,timeZone,false);
  const ageDays = birthDay ? dayDifference(raw.birthAt) : null;
  const maturity = birthDay ? addMonths(birthDay,settings.minimumAgeMonths ?? 10) : null;
  const readiness = cycle?.completedParity !== 0 ? "按经产母羊阶段核对" : !birthDay ? "缺少出生日期，待核实" : today <= maturity ? "未超过参配月龄" : (settings.youthBreedingConfirmedSheepIDs??[]).some(id=>id.toLowerCase()===sheep.id.toLowerCase()) ? "已人工确认" : "待人工确认";
  const gestation = workspace.models?.FarmCareRuleRecord?.find(r=>r.deletedAt==null)?.gestationDays ?? 150;
  const expectedDue = cycle?.pregnancy === "pregnant" && !cycle.issues.length && cycle.breeding ? addDays(farmDateText(cycle.breeding.occurredAt,timeZone,false),gestation) : null;
  const purposeFacts = useMemo(() => (workspace.events??[]).filter(e=>e.relatedSheepIDs?.includes(sheep.id) && e.label==="用途变更" && new Date(e.at).getTime()<=asOf).sort((a,b)=>new Date(b.at)-new Date(a.at)), [workspace.events,sheep.id,asOf]);
  const latestPurpose = purposeFacts[0];
  const fatteningStart = raw?.purpose === "育肥羊" && latestPurpose?.fields?.some(f=>f.label==="新用途"&&f.value==="育肥羊") ? latestPurpose.at : null;
  const fatteningIntervals = fatteningStart ? growth.allIntervals.filter(r=>new Date(r.start.at)>=new Date(fatteningStart)) : [];
  const fatteningDays = fatteningIntervals.reduce((sum,r)=>sum+r.intervalDays,0);
  const weaning = (workspace.models?.WeaningRecord??[]).filter(r=>r.sheepID===sheep.id&&r.deletedAt==null&&r.occurredAt<=asOf).sort((a,b)=>b.occurredAt-a.occurredAt)[0];
  return <section className="sheep-production-detail">
    <h3>生产信息</h3>
    <p>{sheep.purpose || sheep.stage} · {present ? "当前在群" : "历史档案"}</p>
    {ageDays != null ? <p>日龄 {ageDays} 天 · {weaning ? `已断奶（${farmDateText(weaning.occurredAt,timeZone,false)}）` : ["哺乳羔羊","断奶羔羊"].includes(raw?.purpose) ? "未记录断奶事实" : ""}</p> : null}
    {raw?.purpose === "育肥羊" ? <p>{fatteningStart ? `本次育肥开始：${farmDateText(fatteningStart,timeZone,false)}${fatteningDays ? ` · 本次育肥期日增重 ${number(fatteningIntervals.reduce((sum,r)=>sum+r.totalGainKilograms,0)/fatteningDays*1000)} 克/天（${fatteningDays} 天）` : " · 尚无完整称重区间"}` : "缺少可确认的育肥开始记录，暂不能计算育肥期表现。"}</p> : null}
    {raw?.sexRawValue === "ram" ? <section className="sheep-cycle-card"><h3>{raw.isBreedingRam ? "种公羊生产记录" : "公羊生产记录"}</h3><p>已记录配种 {(workspace.models?.ReproductionRecord??[]).filter(r=>r.sireID===sheep.id&&r.kindRawValue==="breeding"&&r.deletedAt==null&&r.occurredAt<=asOf).length} 条</p><details><summary>已关联后代</summary>{(workspace.models?.SheepRecord??[]).filter(s=>s.sireID===sheep.id&&s.deletedAt==null).map(s=><p key={s.id}>{s.earTag} · {s.purpose}</p>)}</details></section> : null}
    {!present && raw?.removedAt ? <p>离群日期：{farmDateText(raw.removedAt,timeZone,false)}</p> : null}
    {preBreedingLamb ? <section className="sheep-cycle-card"><strong>羔羊，未进入繁殖管理</strong><p>尚无自身繁殖记录，不因缺少胎次资料列入繁殖待核实。</p></section> : cycle ? <section className="sheep-cycle-card">
      <strong className={cycle.pregnancy === "uncertain" ? "cycle-review" : ""}>{cycle.displayState}</strong>
      <dl><div><dt>已完成产羔胎次</dt><dd>{cycle.completedParity == null ? "待核实" : `${cycle.completedParity} 胎`}</dd></div><div><dt>本轮目标胎次</dt><dd>{cycle.targetParity == null ? "待核实" : `第 ${cycle.targetParity} 胎`}</dd></div>
        <div><dt>本轮配种</dt><dd>{cycle.breeding ? farmDateText(cycle.breeding.occurredAt,timeZone,false) : "未记录"}</dd></div>
        <div><dt>本轮检胎</dt><dd>{cycle.check ? `${farmDateText(cycle.check.occurredAt,timeZone,false)} · ${cycle.check.result}` : "未检胎"}</dd></div>
        {cycle.lastLambingAt ? <div><dt>距上次产羔</dt><dd>{dayDifference(cycle.lastLambingAt)} 天</dd></div> : null}
        {expectedDue ? <div><dt>预计产羔（估算）</dt><dd>{expectedDue}</dd></div> : null}
        <div><dt>参配确认</dt><dd>{readiness}</dd></div>
      </dl>
      {cycle.issues.length ? <div role="status" className="cycle-review"><strong>繁殖资料待核实</strong>{cycle.issues.map(issue => <p key={issue}>{issue}</p>)}</div> : null}
      {cycle.pregnancy === "recheck" ? <p className="cycle-review">待复检，请核对后续检查。</p> : null}
      <details><summary>本轮依据与繁殖历史</summary>{facts.map(fact => <div className="cycle-fact" key={fact.id}>
        <p>{farmDateText(fact.occurredAt,timeZone)} · {({parityBaseline:"胎次确认",breeding:"配种",pregnancyCheck:"孕检",lambing:"产羔",abortion:"流产"})[fact.kindRawValue]} · {fact.result || (fact.parity == null ? "" : `第 ${fact.parity} 胎`)}</p>
        <small>{cycle.associations.find(a=>a.recordID===fact.id)?.reason ?? "历史周期事实"}</small>
        <ReproductionAssociationEditor key={fact.id} workspace={workspace} record={fact} onSubmit={onReproductionSubmit}/>
      </div>)}</details>
      {present ? <div className="detail-actions"><button className="secondary-button" onClick={()=>onCreateRecord("reproduction",{values:{"母羊耳号列表":sheep.earTag,"类型":"孕检"}})}>记录孕检</button><button className="secondary-button" onClick={()=>onCreateRecord("lambing",{values:{"母羊耳号":sheep.earTag}})}>记录产羔</button></div> : null}
    </section> : null}
    <h3>体重与区间日增重</h3>
    <div className="growth-metrics"><span>最近实测体重<strong>{number(growth.latest?.kilograms,2)} 千克</strong></span><span>最近区间日增重<strong>{number(growth.latestInterval?.gramsPerDay)} 克/天</strong></span></div>
    {growth.latest ? <p>最近称重：{growth.latest.day} · 距今 {dayDifference(growth.latest.at)} 天{weighingDays && dayDifference(growth.latest.at)>=weighingDays ? " · 待称重" : ""}</p> : null}
    {growth.latestInterval?.gramsPerDay < 0 ? <p className="cycle-review">最近区间体重下降，请核对称重与同期健康记录。</p> : null}
    <label>查看范围<select value={range} onChange={e=>{setRange(e.target.value);setSelectedID(null);}}><option value="quarter">近三个月</option><option value="half">近半年</option><option value="all">全部</option><option value="custom">自定义</option></select></label>
    {range === "custom" ? <div className="growth-dates"><label>开始日期<input type="date" value={from} max={today} onChange={e=>setFrom(e.target.value)}/></label><label>结束日期<input type="date" value={to} max={today} onChange={e=>setTo(e.target.value)}/></label></div> : null}
    <p>所选范围：{start || growth.points[0]?.day || "—"}—{end}</p>
    {start && start>end ? <p role="alert">开始日期晚于结束日期，请调整。</p> : null}
    {!growth.points.length ? <div className="empty-state">此范围无体重记录。{range!=="all"?<button onClick={()=>setRange("all")}>查看全部</button>:null}</div> : <>
      <TrendChart points={growth.points.map(p=>({id:p.id,at:new Date(p.at).getTime(),value:p.kilograms,label:p.day}))} label="体重（千克）" selectedID={selected?.id} onSelect={setSelectedID} highlights={selected?[selected.start.id,selected.end.id]:[]} markers={markers} onSelectMarker={setMarkerID} timeZone={timeZone} domain={chartDomain}/>
      {growth.intervals.length ? <TrendChart points={growth.intervals.map(r=>({id:r.id,at:new Date(r.end.at).getTime(),value:r.gramsPerDay,label:`${r.start.day}—${r.end.day}`}))} label="区间日增重（克/天）" selectedID={selected?.id} onSelect={setSelectedID} includesZero markers={markers} onSelectMarker={setMarkerID} timeZone={timeZone} domain={chartDomain}/> : <p>缺少另一日期的有效体重，所选范围暂不能计算日增重。</p>}
    </>}
    {markerID ? <p role="status">{markers.find(m=>m.id===markerID)?.detail}</p> : null}
    {selected ? <IntervalEvidence interval={selected}/> : null}
    {growth.observationDays ? <p>范围平均日增重：<strong>{number(growth.meanGramsPerDay)} 克/天</strong> · 有效观察 {growth.observationDays} 天</p> : null}
    <details><summary>全部区间（{growth.intervals.length}）</summary>{growth.intervals.map(interval=><button className="growth-interval-button" key={interval.id} onClick={()=>setSelectedID(interval.id)}><IntervalEvidence interval={interval}/></button>)}</details>
    {markers.length?<details><summary>期间转群与用途变更</summary>{markers.map(e=><button className="growth-interval-button" key={e.id} onClick={()=>setMarkerID(e.id)}>{farmDateText(e.at,timeZone,false)} · {e.detail}</button>)}</details>:null}
    <p className="growth-note">区间日增重＝两次体重差÷实际天数。范围平均按总增重÷总观察天数计算。连线表示趋势，不代表每天均有测量；跨舍区间不归因为某一圈舍的独立贡献。</p>
  </section>;
}

function addDays(day,days) { const d=new Date(`${day}T12:00:00Z`);d.setUTCDate(d.getUTCDate()+days);return d.toISOString().slice(0,10); }
function addMonths(day,months) { const d=new Date(`${day}T12:00:00Z`),n=d.getUTCDate();d.setUTCDate(1);d.setUTCMonth(d.getUTCMonth()+months);const last=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();d.setUTCDate(Math.min(n,last));return d.toISOString().slice(0,10); }

function IntervalEvidence({interval:r}) { return <div className="growth-evidence"><strong>{r.start.day} → {r.end.day} · {r.intervalDays} 天</strong><p>{number(r.start.kilograms,2)} → {number(r.end.kilograms,2)} 千克 · 增重 {number(r.totalGainKilograms,2)} 千克</p><p>区间日增重 {number(r.gramsPerDay)} 克/天（{number(r.kilogramsPerDay,3)} 千克/天）</p><small>来源：{sourceNames[r.start.source]??r.start.source} → {sourceNames[r.end.source]??r.end.source}</small></div>; }

function TrendChart({points,label,selectedID,onSelect,includesZero=false,highlights=[],markers=[],onSelectMarker,timeZone,domain}) {
  const width=560,height=170,left=58,right=15,top=18,bottom=30;
  const minX=domain?.[0]??Math.min(...points.map(p=>p.at)),maxX=Math.max(domain?.[1]??Math.max(...points.map(p=>p.at)),minX+86400000);
  let low=Math.min(...points.map(p=>p.value),includesZero?0:Infinity),high=Math.max(...points.map(p=>p.value),includesZero?0:-Infinity);
  const pad=Math.max((high-low)*0.12,includesZero?10:0.5);low-=pad;high+=pad;
  const x=at=>left+(at-minX)/(maxX-minX)*(width-left-right),y=v=>top+(high-v)/(high-low)*(height-top-bottom);
  return <div className="growth-chart"><strong>{label}</strong><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${label}折线图，共 ${points.length} 个点`}>
    {[low,(low+high)/2,high].map(value=><g key={value}><line x1={left} x2={width-right} y1={y(value)} y2={y(value)} className="growth-grid"/><text x={left-7} y={y(value)+4} textAnchor="end">{number(value,label.includes("体重")?1:0)}</text></g>)}
    {includesZero?<line x1={left} x2={width-right} y1={y(0)} y2={y(0)} className="growth-zero"/>:null}
    {markers.filter(m=>new Date(m.at).getTime()>=minX&&new Date(m.at).getTime()<=maxX).map(m=><line key={m.id} x1={x(new Date(m.at).getTime())} x2={x(new Date(m.at).getTime())} y1={top} y2={height-bottom} className="growth-marker" role="button" tabIndex="0" aria-label={m.detail} onClick={()=>onSelectMarker(m.id)} onKeyDown={e=>{if(e.key==="Enter"||e.key===" "){e.preventDefault();onSelectMarker(m.id);}}}><title>{farmDateText(m.at,timeZone,false)} · {m.detail}</title></line>)}
    <polyline points={points.map(p=>`${x(p.at)},${y(p.value)}`).join(" ")} fill="none" stroke={includesZero?"#b97719":"#267d70"} strokeWidth="2.5"/>
    {points.map(p=><circle key={p.id} cx={x(p.at)} cy={y(p.value)} r={selectedID===p.id||highlights.includes(p.id)?6:4} fill={includesZero?"#b97719":"#267d70"} tabIndex="0" role="button" aria-label={`${p.label}，${label} ${number(p.value,includesZero?0:2)}`} onClick={()=>onSelect(p.id)} onKeyDown={e=>{if(e.key==="Enter"||e.key===" "){e.preventDefault();onSelect(p.id);}}}><title>{p.label} · {number(p.value,includesZero?0:2)}</title></circle>)}
    <text x={left} y={height-5}>{farmDateText(minX,timeZone,false).slice(5,10)}</text><text x={width-right} y={height-5} textAnchor="end">{farmDateText(maxX,timeZone,false).slice(5,10)}</text>
  </svg></div>;
}
