import { useState } from "react";
import { pregnancyNames } from "../../lib/reproductionCycles.js";
import { farmDateText } from "../../lib/eventExport.js";

export default function ReproductionManagementPanel({workspace,onNavigate,onSubmit}) {
  const [editing,setEditing]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState("");
  const rule=workspace.models?.FarmCareRuleRecord?.find(r=>r.deletedAt==null);
  const initial=workspace.reproductionSettings??{minimumAgeMonths:10,penUsages:{},scopeConfigured:false,selectedPenIDs:[],youthBreedingConfirmedSheepIDs:[]};
  const [settings,setSettings]=useState(initial),[weighing,setWeighing]=useState(initial.weighingReminderDays??""),[draftID]=useState(()=>crypto.randomUUID());
  const canManage=["owner","administrator"].includes(workspace.farm.role),review=workspace.reproductionReview??[],timeZone=workspace.farm.timeZoneIdentifier||"Asia/Shanghai";
  async function save(){setBusy(true);setError("");try{
    const value={...settings,weighingReminderDays:weighing===""?null:Number(weighing)};
    const result=await onSubmit({sheet:"繁殖管理设置",values:{},reproductionAction:"settings",reproductionDraft:{id:draftID,settings:value,expectedSettingsJSON:rule?.reproductionSettingsJSON??null}},draftID);
    setError(result.refreshed?"云端已接受并更新资料。":"云端已接受，刷新尚未完成，请刷新后核对。");setEditing(false);
  }catch(e){setError(e.message);}finally{setBusy(false);}}
  return <section className="workspace-panel flat-panel analysis-secondary-panel">
    <div className="panel-heading"><h2>当前繁殖管理</h2><span>胎次与周期统一投影 · {workspace.lastSyncedAt?farmDateText(workspace.lastSyncedAt,timeZone):"快照时间未提供"}</span></div>
    {!initial.scopeConfigured?<p>尚未设置参与统计的圈舍；单羊繁殖事实仍可查看。</p>:<div className="analysis-metric-strip">{Object.entries(pregnancyNames).map(([key,label])=><article key={key}><small>{label}</small><strong>{workspace.reproductionSummary?.[key]??0}<em>只</em></strong></article>)}</div>}
    {initial.scopeConfigured?<p>所选启用圈舍有母羊 {workspace.reproductionScopeCount??0} 只，其中符合检胎统计条件 {workspace.reproductionEligibleCount??0} 只：有可靠产后日期，或已超过 {initial.minimumAgeMonths} 月龄。</p>:null}
    <details><summary>繁殖资料待核实（含历史 {review.length} 只）</summary><p>尚未到起算月龄且无自身繁殖记录的羔羊不列入。</p>{review.map(row=><button className="growth-interval-button" key={row.sheepID} onClick={()=>onNavigate("sheep",{selectedID:row.sheepID})}><strong>{row.earTag} · {row.isCurrentlyPresent ? "在场" : "离场 / 历史"}</strong><p>{row.issues.join("；")}</p></button>)}</details>
    {canManage&&onSubmit?<button className="secondary-button" onClick={()=>{setSettings(initial);setWeighing(initial.weighingReminderDays??"");setEditing(!editing);}}>参与范围与称重周期设置</button>:null}
    {editing?<div className="form-grid"><label>参配与检胎统计月龄<input type="number" min="1" max="120" value={settings.minimumAgeMonths} onChange={e=>setSettings(s=>({...s,minimumAgeMonths:Number(e.target.value)}))}/></label><label>称重间隔天数（可选）<input type="number" min="1" max="3650" value={weighing} onChange={e=>setWeighing(e.target.value)}/></label><p>留空仅显示距上次称重天数。这里只列当前有羊的启用圈舍。</p>{workspace.pens.filter(p=>p.headCount>0&&p.isActive!==false).map(p=><label key={p.id}><input type="checkbox" checked={settings.selectedPenIDs.some(id=>id.toLowerCase()===p.id.toLowerCase())} onChange={e=>setSettings(s=>({...s,scopeConfigured:true,selectedPenIDs:e.target.checked?[...s.selectedPenIDs,p.id]:s.selectedPenIDs.filter(id=>id.toLowerCase()!==p.id.toLowerCase())}))}/>{p.name} · {p.headCount} 只</label>)}<button disabled={busy} className="primary-button" onClick={save}>{busy?"正在保存…":"保存到牧场"}</button></div>:null}
    {error?<p role="status">{error}</p>:null}
  </section>;
}
