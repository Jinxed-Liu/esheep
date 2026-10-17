import {useMemo} from 'react';
import {resolveReproductionState} from '../lib/reproductionCycles.js';
import {parseBusinessDate,listValues} from '../lib/businessCommands.js';

export default function ReproductionEntryContext({workspace,values,sheet}){
 const tagText=sheet==='产羔'?values['母羊耳号']:values['母羊耳号列表'],dateText=values['发生日期'];
 const rows=useMemo(()=>{
  const keys=new Set(listValues(tagText).map(s=>s.toUpperCase())),facts=workspace.models?.ReproductionRecord??[];
  let at=Date.now();try{if(dateText)at=parseBusinessDate(dateText,workspace.farm.timeZoneIdentifier||'Asia/Shanghai');}catch{}
  const grouped=new Map();for(const r of facts){const group=grouped.get(r.eweID)??[];group.push(r);grouped.set(r.eweID,group);}
  return (workspace.models?.SheepRecord??[]).filter(s=>keys.has(s.earTag.toUpperCase())).map(s=>({earTag:s.earTag,...resolveReproductionState(s.id,grouped.get(s.id)??[],at)}));
 },[workspace.models,workspace.farm.timeZoneIdentifier,tagText,dateText]);
 if(!rows.length)return null;
 return <section className="sheep-cycle-card"><strong>本次事件时间的繁殖依据</strong>{rows.map(s=><p key={s.eweID}>{s.earTag} · {s.displayState} · 已完成 {s.completedParity??'待核实'} 胎 · 本轮目标 {s.targetParity==null?'待核实':`第 ${s.targetParity} 胎`}{s.issues.length?` · ${s.issues.join('；')}`:''}</p>)}<small>逐羊确定周期。补配请选择对应配种；Excel 批量可填写关联配种导入键，分别定位每只母羊。</small></section>;
}
