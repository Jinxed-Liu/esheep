import SheepLabelPanel, {LabelChips, LabelFilter, SheepIdentityImage} from "./SheepLabels.jsx";
import {labelIDs,matchesLabels} from "../../lib/sheepLabels.js";
import { exportEventsCSV,eventExportFileName,downloadFile } from "../../lib/eventExport.js";
import { useEffect, useMemo, useState } from "react";
import { Barn } from "@phosphor-icons/react/Barn";
import { MagnifyingGlass } from "@phosphor-icons/react/MagnifyingGlass";
import { Scales } from "@phosphor-icons/react/Scales";
import { Tag } from "@phosphor-icons/react/Tag";
import { X } from "@phosphor-icons/react/X";
import { formatDateTime, PageTop, ProjectionNotice, Segmented } from "./FeaturePageShared.jsx";

export default function FlockPage({ workspace, initialView = "sheep", selectedID, onCreateRecord, onLabelSubmit }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const baseline = workspace.projectionCoverage?.baseline;
  const [view, setView] = useState(initialView);
  const [filter, setFilter] = useState("");
  const [labelPanel,setLabelPanel]=useState(null);
  const [selectedLabels,setSelectedLabels]=useState([]);
  const [labelMode,setLabelMode]=useState("any");
  const catalog=workspace.models?.SheepLabelRecord??[];
  const assignments=workspace.models?.SheepLabelAssignmentRecord??[];
  const labelAssignment=id=>assignments.find(a=>a.sheepID===id);

  const [page,setPage]=useState(0);
  const [presence,setPresence]=useState("active");
  const [sex,setSex]=useState("");
  const [penFilter,setPenFilter]=useState("");
  const [checked,setChecked]=useState([]);
  const [selection, setSelection] = useState(selectedID ?? null);

  useEffect(()=>{setChecked([]);setPage(0);},[selectedLabels,labelMode,filter,presence,sex,penFilter]);
  useEffect(() => setView(initialView), [initialView]);
  useEffect(() => {
    if (selectedID) setSelection(selectedID);
  }, [selectedID]);

  useEffect(()=>setPage(0),[filter,presence,sex,penFilter]);
  const lowerFilter = filter.trim().toLowerCase();
  const sheepRows = useMemo(
    () => (workspace.allSheep??workspace.sheep).filter(s=>(presence==="all"||presence==="active"?presence==="all"||s.status==="active":s.status!=="active")&&(!sex||s.sex===sex)&&(!penFilter||s.pen===penFilter)).filter(s=>matchesLabels(labelIDs(assignments.find(a=>a.sheepID===s.id)),selectedLabels,labelMode)).filter((sheep) => [sheep.earTag, sheep.breed, sheep.pen, sheep.stage].some((value) => String(value ?? "").toLowerCase().includes(lowerFilter))),
    [lowerFilter, workspace.sheep,workspace.allSheep,presence,sex,penFilter,workspace.models,selectedLabels,labelMode],
  );
  const penRows = useMemo(
    () => workspace.pens.filter((pen) => [pen.name, pen.purpose, pen.status].some((value) => String(value ?? "").toLowerCase().includes(lowerFilter))),
    [lowerFilter, workspace.pens],
  );
  const selectedEntity = view === "sheep"
    ? (workspace.allSheep??workspace.sheep).find((sheep) => sheep.id === selection)
    : workspace.pens.find((pen) => pen.id === selection);

  function changeView(nextView) {
    setView(nextView);
    setSelection(null);
    setFilter("");
  }

  return (
    <main className="page feature-page">
      <PageTop
        title={view === "sheep" ? "羊只" : "圈舍"}
        description={view === "sheep" ? "查看当前在场羊只、生产阶段、圈舍与最近体重。" : "查看有羊圈舍、用途、当前存栏和状态。"}
        actionLabel={view === "sheep" ? "新建羊只" : undefined}
        onAction={() => onCreateRecord("addSheep")}
        icon={Tag}
      />
      <section className="workspace-panel entity-workspace">
        <div className="workspace-toolbar">
          <Segmented items={[{ id: "sheep", label: "羊只" }, { id: "pens", label: "圈舍" }]} value={view} onChange={changeView} />
          <label className="inline-search"><MagnifyingGlass size={18} /><input value={filter} onChange={(event) => setFilter(event.target.value)} placeholder={view === "sheep" ? "筛选耳号、品种或圈舍" : "筛选圈舍、用途或状态"} /></label>
        </div>
        {workspace.mode === "cloud" && workspace.projectionCoverage?.incompleteSheep ? (
          <ProjectionNotice>当前在场数量保留云端有效状态（{workspace.metrics.activeSheep.toLocaleString("zh-CN")} 只）；{baseline?.status === "loaded" ? `紧凑基线已展开，仍有 ${workspace.projectionCoverage.incompleteSheep.toLocaleString("zh-CN")} 只资料不完整。` : `紧凑基线未能读取（${baseline?.reason || "未知原因"}），不猜填旧值。`}</ProjectionNotice>
        ) : null}
        {view==="sheep"?<div className="workspace-toolbar"><label>状态<select value={presence} onChange={e=>setPresence(e.target.value)}><option value="active">在场</option><option value="removed">离场 / 历史</option><option value="all">全部档案</option></select></label><label>性别<select value={sex} onChange={e=>setSex(e.target.value)}><option value="">全部</option><option>母</option><option>公</option></select></label><label>圈舍<select value={penFilter} onChange={e=>setPenFilter(e.target.value)}><option value="">全部</option>{workspace.pens.map(p=><option key={p.id}>{p.name}</option>)}</select></label><span>已选 {checked.length} 只</span><button className="secondary-button" disabled={!checked.length} onClick={()=>onCreateRecord("健康记录",{values:{"羊只耳号列表":checked.join(";"),"类型":"治疗"}})}>批量健康记录</button><button className="secondary-button" disabled={!checked.length} onClick={()=>onCreateRecord("离场",{values:{"羊只耳号列表":checked.join(";"),"类型":"出售"}})}>批量离场</button><button className="secondary-button" disabled={!checked.length} onClick={()=>onCreateRecord("生产批次",{values:{"羊只耳号列表":checked.join(";")}})}>建立生产批次</button></div>:null}
        {view==="sheep"?<div className="workspace-toolbar"><LabelFilter catalog={catalog} selected={selectedLabels} onChange={setSelectedLabels} mode={labelMode} onMode={setLabelMode}/><button className="secondary-button" onClick={()=>setLabelPanel({targets:null})}>标签管理</button><button className="secondary-button" disabled={!checked.length} onClick={()=>setLabelPanel({targets:(workspace.allSheep??workspace.sheep).filter(s=>checked.includes(s.earTag)).map(s=>s.id)})}>批量标签</button></div>:null}
        <div className={`entity-content ${selectedEntity ? "with-detail" : ""}`}>
          <div className="table-scroll">
            {view==="sheep"?<div className="workspace-toolbar"><span>{sheepRows.length} 只 · 第 {page+1} 页</span><button disabled={!page} onClick={()=>setPage(p=>p-1)}>上一页</button><button disabled={(page+1)*100>=sheepRows.length} onClick={()=>setPage(p=>p+1)}>下一页</button></div>:null}
            {view === "sheep" ? (
              <table className="data-table selectable-table">
                <thead><tr><th><input aria-label="选择当前筛选全部羊只" type="checkbox" checked={Boolean(sheepRows.length)&&sheepRows.every(s=>checked.includes(s.earTag))} onChange={e=>setChecked(e.target.checked?sheepRows.map(s=>s.earTag):[])}/></th><th>耳号</th><th>标签</th><th>品种</th><th>性别</th><th>生产阶段</th><th>当前圈舍</th><th>最近体重</th><th>更新时间</th></tr></thead>
                <tbody>{sheepRows.length ? sheepRows.slice(page*100,(page+1)*100).map((sheep) => (
                  <tr className={selection === sheep.id ? "selected" : ""} key={sheep.id} tabIndex="0" onClick={() => setSelection(sheep.id)} onKeyDown={(event) => { if (event.key === "Enter") setSelection(sheep.id); }}>
                    <td onClick={e=>e.stopPropagation()}><input aria-label={`选择 ${sheep.earTag}`} type="checkbox" checked={checked.includes(sheep.earTag)} onChange={e=>setChecked(ids=>e.target.checked?[...ids,sheep.earTag]:ids.filter(id=>id!==sheep.earTag))}/></td><td><SheepIdentityImage sheep={sheep}/><strong>{sheep.earTag}</strong></td><td><LabelChips catalog={catalog} assignment={labelAssignment(sheep.id)}/></td><td>{sheep.breed}</td><td>{sheep.sex}</td><td><span className="status-text">{sheep.stage}</span></td><td>{sheep.pen}</td><td>{sheep.weight == null ? "—" : `${sheep.weight} kg`}</td><td>{formatDateTime(sheep.updatedAt, timeZone)}</td>
                  </tr>
                )) : <tr><td colSpan="9"><div className="empty-state">没有匹配的羊只。</div></td></tr>}</tbody>
              </table>
            ) : (
              <table className="data-table selectable-table">
                <thead><tr><th>圈舍</th><th>用途</th><th>在场羊只</th><th>状态</th><th>最近更新</th></tr></thead>
                <tbody>{penRows.length ? penRows.map((pen) => (
                  <tr className={selection === pen.id ? "selected" : ""} key={pen.id} tabIndex="0" onClick={() => setSelection(pen.id)} onKeyDown={(event) => { if (event.key === "Enter") setSelection(pen.id); }}>
                    <td><strong>{pen.name}</strong></td><td>{pen.purpose}</td><td>{pen.headCount ?? "—"}</td><td><span className={`state-label ${pen.status === "正常" ? "success" : "warning"}`}>{pen.status}</span></td><td>{formatDateTime(pen.updatedAt, timeZone)}</td>
                  </tr>
                )) : <tr><td colSpan="5"><div className="empty-state">没有匹配的有羊圈舍。</div></td></tr>}</tbody>
              </table>
            )}
          </div>
          {selectedEntity ? (
            <aside className="entity-detail-pane">
              <button className="icon-button detail-close" type="button" onClick={() => setSelection(null)} aria-label="关闭详情"><X size={19} /></button>
              <span className="detail-hero-icon">{view === "sheep" ? <SheepIdentityImage sheep={selectedEntity}/> : <Barn size={27} />}</span>
              <p className="eyebrow">{view === "sheep" ? "SHEEP PROFILE" : "PEN PROFILE"}</p>
              <h2>{view === "sheep" ? selectedEntity.earTag : selectedEntity.name}</h2>
              {view === "sheep" ? (
                <>
                  <dl><div><dt>品种 / 性别</dt><dd>{selectedEntity.breed} · {selectedEntity.sex}</dd></div><div><dt>当前圈舍</dt><dd>{selectedEntity.pen}</dd></div><div><dt>生产阶段</dt><dd>{selectedEntity.stage}</dd></div><div><dt>最近体重</dt><dd>{selectedEntity.weight == null ? "—" : `${selectedEntity.weight} kg`}</dd></div><div><dt>更新时间</dt><dd>{formatDateTime(selectedEntity.updatedAt, timeZone)}</dd></div></dl>
                  <dl>{[["出生日期",selectedEntity.birthAt],["入场日期",selectedEntity.enteredAt],["离场日期",selectedEntity.removedAt]].map(([label,date])=><div key={label}><dt>{label}</dt><dd>{date?formatDateTime(date,timeZone):"未填写"}</dd></div>)}{["damID","sireID"].map(key=><div key={key}><dt>{key==="damID"?"母本":"父本"}</dt><dd>{workspace.allSheep?.find(s=>s.id===workspace.models?.SheepRecord?.find(s=>s.id===selectedEntity.id)?.[key])?.earTag??"未关联"}</dd></div>)}</dl>
                  <dl>{(()=>{const raw=workspace.models?.SheepRecord?.find(s=>s.id===selectedEntity.id);if(!raw)return null;return [["在场状态",raw.isHistoricalArchive?"历史档案":({active:"在场",removed:"离场",deceased:"死亡"})[raw.statusRawValue]||raw.statusRawValue],["种公羊",raw.isBreedingRam?"是":"否"],["冻精供体",raw.semenDonorNameSnapshot||"未关联"],["当前胎次",workspace.models?.ReproductionRecord?.filter(r=>r.deletedAt==null&&r.eweID===raw.id&&r.parity!=null).sort((a,b)=>b.occurredAt-a.occurredAt)[0]?.parity??"未确认"],["备注",raw.note||"未填写"],["档案编号",raw.id]].map(([label,value])=><div key={label}><dt>{label}</dt><dd>{value}</dd></div>);})()}</dl>
                  <h3>标签</h3><LabelChips catalog={catalog} assignment={labelAssignment(selectedEntity.id)} limit={100}/><p>主标签：{catalog.find(l=>l.id===labelAssignment(selectedEntity.id)?.primaryLabelID)?.name??"无"}</p><button className="secondary-button" onClick={()=>setLabelPanel({targets:[selectedEntity.id]})}>编辑标签与档案</button>
                  <details><summary>标签变更记录</summary>{(workspace.models?.SheepLabelChangeRecord??[]).filter(c=>c.sheepID===selectedEntity.id).sort((a,b)=>b.occurredAt-a.occurredAt).map(c=><p key={c.id}>{formatDateTime(c.occurredAt,timeZone)} · {c.detail} · 操作账号：{c.accountID}</p>)}</details>
                  <h3>完整业务历史</h3><button className="secondary-button" onClick={()=>downloadFile(exportEventsCSV(workspace.events.filter(e=>e.relatedSheepIDs?.includes(selectedEntity.id)),{timeZone}),eventExportFileName(`${workspace.farm.name}_${selectedEntity.earTag}`,{timeZone}))}>导出此羊全部事件</button><div className="sheep-event-history">{workspace.events.filter(e=>e.relatedSheepIDs?.includes(selectedEntity.id)).map(e=><details key={e.id}><summary>{formatDateTime(e.at,timeZone)} · {e.label}</summary><p>{e.detail}</p><p>{e.note}</p><dl>{e.fields?.map(f=><div key={f.label}><dt>{f.label}</dt><dd>{f.value}</dd></div>)}</dl></details>)}</div>
                  <div className="detail-actions"><button className="primary-button" type="button" onClick={() => onCreateRecord("weight",{values:{"耳号":selectedEntity.earTag}})}><Scales size={18} />记录称重</button><button className="secondary-button" type="button" onClick={() => onCreateRecord("transfer",{values:{"耳号":selectedEntity.earTag}})}>转群</button></div>
                </>
              ) : (
                <>
                  <dl><div><dt>用途</dt><dd>{selectedEntity.purpose}</dd></div><div><dt>当前羊只</dt><dd>{selectedEntity.headCount ?? "—"} 只</dd></div><div><dt>状态</dt><dd>{selectedEntity.status}</dd></div><div><dt>更新时间</dt><dd>{formatDateTime(selectedEntity.updatedAt, timeZone)}</dd></div></dl>
                  <div className="detail-actions"><button className="primary-button" type="button" onClick={() => onCreateRecord("feed")}><Barn size={18} />记录投喂</button></div>
                </>
              )}
            </aside>
          ) : null}
        </div>
        <footer className="panel-footer">{view === "sheep" ? `当前显示 ${sheepRows.length} 条记录` : `当前显示 ${penRows.length} 个有羊圈舍`}</footer>
      </section>
    {labelPanel?<SheepLabelPanel workspace={workspace} targets={labelPanel.targets} onClose={()=>setLabelPanel(null)} onSubmit={onLabelSubmit} onViewLabel={id=>{setSelectedLabels([id]);setLabelMode("any");setPresence("active");}}/>:null}
    </main>
  );
}
