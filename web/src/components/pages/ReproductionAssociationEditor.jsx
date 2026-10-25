import { useState } from "react";
import { farmDateText } from "../../lib/eventExport.js";

export default function ReproductionAssociationEditor({workspace,record,onSubmit}) {
  const [open,setOpen]=useState(false),[intent,setIntent]=useState(record.breedingIntentRawValue??"newRound"),[relatedID,setRelatedID]=useState(record.relatedBreedingRecordID??""),[reason,setReason]=useState(""),[busy,setBusy]=useState(false),[message,setMessage]=useState("");
  const [draftID]=useState(()=>crypto.randomUUID());
  if(!onSubmit||!["owner","administrator"].includes(workspace.farm.role)||!["breeding","pregnancyCheck","abortion"].includes(record.kindRawValue))return null;
  const tz=workspace.farm.timeZoneIdentifier||"Asia/Shanghai";
  const candidates=(workspace.models?.ReproductionRecord??[]).filter(r=>r.eweID===record.eweID&&r.kindRawValue==="breeding"&&r.id!==record.id&&r.deletedAt==null&&r.occurredAt<record.occurredAt);
  async function save(){setBusy(true);setMessage("");try{
    const result=await onSubmit({sheet:"繁殖关联核实",values:{},reproductionAction:"associate",reproductionDraft:{id:draftID,recordID:record.id,expectedRevision:record.revision,intent,relatedID:record.kindRawValue==="breeding"&&intent==="newRound"?null:relatedID||null,reason}},draftID);
    setMessage(result.refreshed?"关联已保存并刷新。":"云端已接受，请刷新后核对关联。");setOpen(false);
  }catch(error){setMessage(error.message);}finally{setBusy(false);}}
  return <div><button className="text-button" onClick={()=>setOpen(!open)}>核实／修正关联</button>{open?<div className="form-grid">
    {record.kindRawValue==="breeding"?<label>配种轮次<select value={intent} onChange={e=>{setIntent(e.target.value);setRelatedID("");}}><option value="newRound">新一轮配种</option><option value="supplement">本轮补配</option></select></label>:null}
    {record.kindRawValue!=="breeding"||intent==="supplement"?<label>对应配种<select value={relatedID} onChange={e=>setRelatedID(e.target.value)}><option value="">未明确关联</option>{candidates.map(r=><option key={r.id} value={r.id}>{farmDateText(r.occurredAt,tz)} · {workspace.allSheep?.find(s=>s.id===r.sireID)?.earTag??r.semenNameSnapshot??"父本未记录"}</option>)}</select></label>:null}
    <label>核实原因<textarea value={reason} onChange={e=>setReason(e.target.value)}/></label><p>本次保留原始检查结果和发生时间，仅修正关联并保存审计记录。</p>
    <button className="primary-button" disabled={busy||!reason.trim()} onClick={save}>{busy?"正在保存…":"保存关联"}</button>
  </div>:null}{message?<p role="status">{message}</p>:null}</div>;
}
