import {useMemo,useState} from "react";
import {labelColors,labelColorNames,labelRestriction,labelAllows,labelIDs,orderedLabels,labelState} from "../../lib/sheepLabels.js";
import "./SheepLabels.css";
export function EarTagIcon({color,size=28}) {return <img className="ear-tag-icon" width={size} height={Math.round(size*8/11)} src={`/assets/ear-tags/${color}.png`} alt=""/>;}
export function SheepIdentityImage({sheep}) {
  const [failed,setFailed]=useState(false);
  const sex=sheep.sexRawValue??(sheep.sex==="公"?"ram":sheep.sex==="母"?"ewe":"unknown");
  const photo=sheep.avatarURL??sheep.avatarUrl??sheep.photoURL;
  return photo&&!failed?<img className="sheep-identity-photo" src={photo} onError={()=>setFailed(true)} alt={`${sheep.earTag} 头像`}/>:sex==="unknown"?<span className="sheep-unknown" aria-label="性别未知">?</span>:<EarTagIcon color={sex==="ram"?"yellow":"green"} size={40}/>;
}
export function LabelChips({catalog,assignment,limit=2}) {
  const ids=labelIDs(assignment), labels=orderedLabels(catalog.filter(l=>ids.includes(l.id)),assignment?.primaryLabelID);
  return <span className="sheep-label-chips">{labels.slice(0,limit).map(l=><span className="sheep-label-chip" key={l.id}><EarTagIcon color={l.colorRawValue}/><span>{l.name}{!l.isActive?" · 已停用":""}</span></span>)}{labels.length>limit?<span>＋{labels.length-limit}</span>:null}</span>;
}
export function LabelFilter({catalog,selected,onChange,mode,onMode}) {
  return <details className="label-filter"><summary>标签筛选{selected.length?`（${selected.length}）`:""}</summary><div className="label-filter-content"><select aria-label="标签匹配方式" value={mode} onChange={e=>onMode(e.target.value)}><option value="any">匹配任一标签</option><option value="all">同时包含全部</option><option value="none">无自定义标签</option></select>{catalog.map(l=><label key={l.id}><input type="checkbox" disabled={mode==="none"} checked={selected.includes(l.id)} onChange={e=>onChange(e.target.checked?[...selected,l.id]:selected.filter(id=>id!==l.id))}/><EarTagIcon color={l.colorRawValue}/>{l.name}</label>)}<button onClick={()=>{onChange([]);onMode("any");}}>清除标签筛选</button></div></details>;
}
export default function SheepLabelPanel({workspace,targets=null,onSubmit,onClose,onViewLabel}) {
  const state=useMemo(()=>labelState(workspace.models??{},workspace.farm.id),[workspace]);
  const [query,setQuery]=useState("");
  const [editing,setEditing]=useState(null);
  const [operation,setOperation]=useState("add");
  const single=targets?.length===1;
  const assignment=single?state.assignments.find(a=>a.sheepID===targets[0]):null;
  const [selected,setSelected]=useState(single?labelIDs(assignment):[]);
  const [initial]=useState(single?labelIDs(assignment):[]);
  const [primary,setPrimary]=useState(assignment?.primaryLabelID??"");
  const [applicable,setApplicable]=useState(false);
  const [busy,setBusy]=useState(false);
  const [results,setResults]=useState(null);
  const [pending,setPending]=useState(null);
  const [error,setError]=useState("");
  const [profile,setProfile]=useState(null);
  const [confirmRemoval,setConfirmRemoval]=useState(false);
  const role=workspace.farm.role;
  const canManage=["owner","administrator"].includes(role)||workspace.capabilities?.includes?.("manageCatalogs");
  const canRecord=["owner","administrator","worker"].includes(role);
  const subjects=state.sheep.filter(s=>targets?.includes(s.id));
  const catalog=orderedLabels(state.catalog);
  const eligible=(l,s)=>operation==="remove"||(l.isActive&&labelAllows(l.colorRawValue,s.sexRawValue));
  const incompatible=!single&&catalog.some(l=>selected.includes(l.id)&&subjects.some(s=>!eligible(l,s)));
  const conflictLabels=profile?catalog.filter(l=>labelIDs(assignment).includes(l.id)&&!labelAllows(l.colorRawValue,profile.sex)):[];
  async function submit(actions) {
    setBusy(true);setError("");setPending(actions);
    try {const result=await onSubmit(actions);setResults(result);setPending(result.filter(r=>!r.accepted).map(r=>r.action));return result;}
    catch(e){setError(e.message);return null;}finally{setBusy(false);}
  }
  async function deleteLabel() {
    if(!window.confirm(`彻底删除“${editing?.name??""}”？这会清理所有羊只关联，且不能恢复。`))return;
    const result=await submit([{action:"deleteLabel",draft:{id:editing.id,changeID:crypto.randomUUID(),expectedRevision:editing.expectedRevision},display:editing.name}]);
    if(result?.every(r=>r.accepted))setEditing(null);
  }
  function saveLabels() {
    if(pending?.length)return submit(pending);
    const actions=[];
    for(const s of subjects) {
      const a=state.assignments.find(a=>a.sheepID===s.id);
      const allowed=catalog.filter(l=>selected.includes(l.id)&&eligible(l,s)).map(l=>l.id);
      if(!single&&!allowed.length)continue;
      actions.push({action:"editLabels",draft:{id:crypto.randomUUID(),sheepID:s.id,addIDs:single?selected.filter(id=>!initial.includes(id)):operation==="remove"?[]:allowed,removeIDs:single?initial.filter(id=>!selected.includes(id)):operation==="remove"?selected:[],setsPrimary:single?primary!==(assignment?.primaryLabelID??""):operation==="primary",primaryLabelID:single?primary||null:allowed[0]??null,expectedRevision:a?.revision??0},display:s.earTag});
    }
    if(!actions.length){setError("没有可处理的羊只。");return;}
    submit(actions);
  }
  function newLabel(){setEditing({id:crypto.randomUUID(),changeID:crypto.randomUUID(),name:"",color:"red",note:"",sortOrder:Math.max(-1,...catalog.map(l=>l.sortOrder))+1,isActive:true,expectedRevision:0});setResults(null);}
  return <div className="label-modal-backdrop"><section className="label-modal" role="dialog" aria-modal="true" aria-labelledby="label-panel-title"><header><div><p className="eyebrow">eSheep+ · 羊只标签</p><h2 id="label-panel-title">{profile?"编辑档案与标签":editing?"编辑标签":targets?single?"编辑羊只标签":`批量标签 · ${subjects.length} 只`:"标签管理"}</h2></div><button aria-label="关闭标签面板" onClick={onClose} disabled={busy}>关闭</button></header>
    {error?<p role="alert" className="label-error">{error}</p>:null}
    {profile?<div className="label-form"><label>耳号<input value={profile.earTag} onChange={e=>setProfile({...profile,earTag:e.target.value})}/></label><label>品种<input value={profile.breed} onChange={e=>setProfile({...profile,breed:e.target.value})}/></label><label>性别<select value={profile.sex} onChange={e=>{setProfile({...profile,sex:e.target.value});setConfirmRemoval(false);}}><option value="ram">公羊</option><option value="ewe">母羊</option><option value="unknown">未知</option></select></label><label>备注<textarea value={profile.note} onChange={e=>setProfile({...profile,note:e.target.value})}/></label>{conflictLabels.length?<div><p>需移除：{conflictLabels.map(l=>l.name).join("、")}</p><label><input type="checkbox" checked={confirmRemoval} onChange={e=>setConfirmRemoval(e.target.checked)}/>确认移除上述标签并保存性别修改</label></div>:null}<button className="primary-button" disabled={busy||(!confirmRemoval&&conflictLabels.length>0)} onClick={()=>submit([{action:"patchProfile",draft:{...profile,removeLabelIDs:conflictLabels.map(l=>l.id)},display:profile.earTag}])}>提交档案修改</button></div>:editing?<div className="label-form"><label>名称<input maxLength={40} value={editing.name} onChange={e=>setEditing({...editing,name:e.target.value})}/></label><fieldset><legend>颜色 · {labelRestriction(editing.color)}</legend><div className="label-palette">{labelColors.map(c=><button className={editing.color===c?"selected":""} key={c} aria-pressed={editing.color===c} onClick={()=>setEditing({...editing,color:c})}><EarTagIcon color={c} size={48}/><span>{labelColorNames[c]}</span></button>)}</div></fieldset><label>说明<textarea maxLength={500} value={editing.note} onChange={e=>setEditing({...editing,note:e.target.value})}/></label><label>展示顺序<input type="number" min="0" value={editing.sortOrder} onChange={e=>setEditing({...editing,sortOrder:Number(e.target.value)})}/></label><label><input type="checkbox" checked={editing.isActive} onChange={e=>setEditing({...editing,isActive:e.target.checked})}/>启用</label><div className="label-actions"><button onClick={()=>setEditing(null)}>返回列表</button>{editing.expectedRevision>0?<button className="danger-button" disabled={busy||!canManage} onClick={deleteLabel}>彻底删除</button>:null}<button className="primary-button" disabled={busy||!canManage||results?.some(r=>r.accepted)} onClick={()=>submit([{action:"saveLabel",draft:editing,display:editing.name}])}>提交标签</button></div></div>:<>
    <div className="label-actions"><input aria-label="搜索标签名称" placeholder="搜索标签名称" value={query} onChange={e=>setQuery(e.target.value)}/>{!targets?<button className="primary-button" onClick={newLabel} disabled={!canManage}>新建标签</button>:null}</div>
    {targets&&!single?<label>批量操作<select value={operation} onChange={e=>{setOperation(e.target.value);setSelected([]);setApplicable(false);}}><option value="add">添加标签</option><option value="remove">移除标签</option><option value="primary">设为主标签</option></select></label>:null}
    <div className="label-catalog">{catalog.filter(l=>l.name.toLowerCase().includes(query.toLowerCase())).map(l=>{const count=subjects.filter(s=>eligible(l,s)).length;const allowed=!single||eligible(l,subjects[0]);const members=state.assignments.filter(a=>labelIDs(a).includes(l.id)).map(a=>a.sheepID);return <div className="label-catalog-row" key={l.id}>{targets?<input type="checkbox" aria-label={`选择标签 ${l.name}`} disabled={!allowed&&!selected.includes(l.id)||busy||!!results} checked={selected.includes(l.id)} onChange={e=>setSelected(e.target.checked?operation==="primary"?[l.id]:[...selected,l.id]:selected.filter(id=>id!==l.id))}/>:null}<EarTagIcon color={l.colorRawValue} size={46}/><div className="label-row-description"><strong>{l.name}{!l.isActive?" · 已停用":""}</strong><small>{labelRestriction(l.colorRawValue)}{targets&&!single&&selected.includes(l.id)?` · 可处理 ${count} 只 · 不适用 ${subjects.length-count} 只`:""}</small>{l.note?<p>{l.note}</p>:null}</div>{!targets?<><button onClick={()=>{onViewLabel(l.id);onClose();}}>{state.sheep.filter(s=>members.includes(s.id)&&s.statusRawValue==="active"&&!s.isHistoricalArchive).length} 只在群</button><button disabled={!canManage} onClick={()=>{setEditing({id:l.id,changeID:crypto.randomUUID(),name:l.name,color:l.colorRawValue,note:l.note,sortOrder:l.sortOrder,isActive:l.isActive,expectedRevision:l.revision});setResults(null);}}>编辑</button></>:null}</div>;})}{!catalog.length?<p className="label-empty">牧场尚无自定义标签。可以创建“重点观察”“留种候选”或“资料待核对”。</p>:null}</div>
    {single?<label>主标签<select value={primary} onChange={e=>setPrimary(e.target.value)} disabled={!!results}><option value="">按牧场顺序选择</option>{catalog.filter(l=>selected.includes(l.id)&&l.isActive).map(l=><option key={l.id} value={l.id}>{l.name}</option>)}</select></label>:null}
    {incompatible?<label className="label-confirm"><input type="checkbox" checked={applicable} onChange={e=>setApplicable(e.target.checked)}/>仅应用到符合条件的羊只；其他羊只不添加对应标签。</label>:null}
    {targets?<div className="label-actions">{single?<button disabled={busy||!canRecord} onClick={()=>{const s=subjects[0];setProfile({id:crypto.randomUUID(),sheepID:s.id,earTag:s.earTag,breed:s.breed,sex:s.sexRawValue,birthAt:s.birthAt,note:s.note,expectedRevision:s.revision});setResults(null);}}>编辑档案与性别</button>:null}<button className="primary-button" disabled={busy||!canRecord||(incompatible&&!applicable)||(!!results&&!pending?.length)} onClick={saveLabels}>{busy?"正在提交…":pending?.length?"重试失败项":"提交标签修改"}</button></div>:null}
    </>}
    {results?<div className="label-results" role="status"><strong>云端已接受 {results.filter(r=>r.accepted).length} 项，失败 {results.filter(r=>!r.accepted).length} 项。</strong>{results.map((r,i)=><p key={i}>{r.action.display}：{r.accepted?"云端已接受":r.error}</p>)}</div>:null}
  </section></div>;
}
