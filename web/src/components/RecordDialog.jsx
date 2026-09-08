import { additionalRecordSchemas } from '../lib/additionalRecordSchemas.js';
import { useEffect, useState } from "react";
import { X } from "@phosphor-icons/react/X";
import contract from "../../public/downloads/eSheepPlus_全功能录入模板_v7.json";
import { farmDateText } from "../lib/eventExport.js";
const aliases = { addSheep:"新建羊只",weight:"称重",transfer:"转群",removal:"离场",feed:"投喂",health:"健康记录",note:"备注",reproduction:"繁殖记录",lambing:"产羔",weaning:"断奶" };
export const recordSchemas = [...contract.schemas,...additionalRecordSchemas];
export function RecordDialog({ requestedType, workspace, initialDraft, initialValues, onClose, onSave }) {
  const [sheet,setSheet] = useState(initialDraft?.record.sheet ?? aliases[requestedType] ?? (recordSchemas.some(s=>s.name===requestedType)?requestedType:""));
  const [values,setValues] = useState(initialDraft?.record.values ?? initialValues ?? {});
  const [error,setError] = useState(""); const [busy,setBusy] = useState(false);
  const schema = recordSchemas.find(s=>s.name===sheet);
  useEffect(()=> { const handler = e=>{if(e.key==="Escape"&&!busy)onClose();}; document.addEventListener("keydown",handler);return()=>document.removeEventListener("keydown",handler);},[busy,onClose]);
  async function save(submit) { setBusy(true);setError("");try{await onSave({sheet,values},initialDraft?.id,submit);onClose();}catch(e){setError(e.message);}finally{setBusy(false);} }
  function selectSheet(name) { setSheet(name); const schema=recordSchemas.find(s=>s.name===name);setValues(Object.fromEntries(schema.columns.filter(c=>/日期/.test(c)&&schema.required.includes(c)).map(c=>[c,farmDateText(Date.now(),workspace.farm.timeZoneIdentifier||"Asia/Shanghai",false)]))); }
  const suggestions = column=> column.includes("耳号")?(workspace.allSheep??workspace.sheep).map(s=>s.earTag):column.includes("圈舍")?workspace.pens.map(p=>p.name):[];
  return <div className="modal-backdrop"><section className="record-dialog" role="dialog" aria-modal="true" aria-labelledby="record-dialog-title"><header><span><h2 id="record-dialog-title">{sheet||"新建记录"}</h2><p>可先保存草稿，或核对后正式提交。日期按牧场时区解释。</p></span><button className="icon-button" disabled={busy} onClick={onClose} aria-label="关闭"><X size={23}/></button></header>
    {!schema?<div className="record-type-grid">{recordSchemas.map(s=><button key={s.name} onClick={()=>selectSheet(s.name)}>{s.name}</button>)}</div>:<form onSubmit={e=>{e.preventDefault();save(true);}}><div className="form-grid two-columns">{schema.columns.filter(c=>c!=="导入键").map(column=><label className="record-field" key={column}><span>{column}{schema.required.includes(column)?" *":""}</span>{column.includes("明细")||column.includes("列表")||column==="备注"?<textarea rows={column.includes("明细")?3:2} required={schema.required.includes(column)} value={values[column]??""} onChange={e=>setValues(v=>({...v,[column]:e.target.value}))}/>:<><input required={schema.required.includes(column)} list={`suggest-${column}`} value={values[column]??""} onChange={e=>setValues(v=>({...v,[column]:e.target.value}))} placeholder={schema.example[schema.columns.indexOf(column)]||(/日期/.test(column)?"yyyy-MM-dd HH:mm:ss":"")}/>{suggestions(column).length>0?<datalist id={`suggest-${column}`}>{suggestions(column).map(value=><option key={value} value={value}/>)}</datalist>:null}</>}</label>)}</div>{sheet==="产羔"?<p>产羔明细：耳号|母羊或公羊|体重|称重日期|是否建档|是否死胎，多只用分号分隔。</p>:null}{sheet==="投喂"?<p>投喂明细：原料名称|公斤数，多项用分号分隔。方式填写“限量投喂”或“自由采食”。</p>:null}{schema.hint?<p>{schema.hint}</p>:null}{error?<p className="form-error" role="alert">{error}</p>:null}<footer><button type="button" className="text-button" disabled={busy||Boolean(initialDraft)} onClick={()=>setSheet("")}>选择其他类型</button><div><button type="button" className="secondary-button" disabled={busy} onClick={()=>save(false)}>保存草稿</button><button className="primary-button" disabled={busy}>{busy?"正在保存…":"正式提交云端"}</button></div></footer></form>}
  </section></div>;
}
