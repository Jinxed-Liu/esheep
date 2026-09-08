import { exportEventsCSV, matchingEvents, eventExportContract, eventExportFileName, downloadFile } from "../../lib/eventExport.js";
import { useEffect, useMemo, useState } from "react";
import { DownloadSimple } from "@phosphor-icons/react/DownloadSimple";
import { MagnifyingGlass } from "@phosphor-icons/react/MagnifyingGlass";
import { X } from "@phosphor-icons/react/X";
import { formatDateTime, PageTop, Segmented } from "./FeaturePageShared.jsx";

function csvCell(value) {
  return `"${String(value ?? "").replaceAll('"', '""')}"`;
}

function eventFieldText(event) {
  return (event.fields ?? []).map((field) => `${field.label}：${field.value}`).join("；");
}

export default function EventsPage({ workspace, selectedID, exportHint = false }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const [page,setPage]=useState(0);
  const [type, setType] = useState("all");
  const [query, setQuery] = useState("");
  const [selection, setSelection] = useState(selectedID ?? null);
  useEffect(() => {
    if (selectedID) setSelection(selectedID);
  }, [selectedID]);
  const [start,setStart]=useState("");const [end,setEnd]=useState("");
  useEffect(()=>setPage(0),[type,query,start,end]);
  const options={scope:type,start,end,query,timeZone};
  const rows = useMemo(()=>matchingEvents(workspace.events,options),[query,type,start,end,timeZone,workspace.events]);
  const selectedEvent = workspace.events.find((event) => event.id === selection);

  function exportCSV() {
    downloadFile(exportEventsCSV(workspace.events,options),eventExportFileName(workspace.farm.name,options));
  }

  return (
    <main className="page feature-page">
      <PageTop title="事件历史" description="按发生时间保留业务事实、修订和同步状态；可筛选、查看详情并导出当前结果。" actionLabel="导出当前结果" onAction={exportCSV} icon={DownloadSimple} />
      {exportHint ? <div className="export-hint">已从首页进入导出：先检查筛选结果，再点击“导出当前结果”。</div> : null}
      <section className="workspace-panel entity-workspace">
        <div className="workspace-toolbar event-toolbar">
          <label>记录类型<select value={type} onChange={e=>setType(e.target.value)}>{eventExportContract.scopes.map(s=><option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
          <label>开始日期<input type="date" value={start} onChange={e=>setStart(e.target.value)}/></label><label>结束日期<input type="date" value={end} onChange={e=>setEnd(e.target.value)}/></label>
          <label className="inline-search"><MagnifyingGlass size={18} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="搜索耳号、重量、原因、圈舍或备注" /></label>
        </div>
        <div className={`entity-content ${selectedEvent ? "with-detail" : ""}`}>
          <div className="table-scroll"><table className="data-table selectable-table event-data-table"><thead><tr><th>发生时间</th><th>事件</th><th>对象</th><th>具体值</th><th>操作人</th><th>同步状态</th><th>修订</th></tr></thead><tbody>
            {rows.length ? rows.slice(page*100,(page+1)*100).map((event) => <tr className={selection === event.id ? "selected" : ""} key={event.id} tabIndex="0" onClick={() => setSelection(event.id)} onKeyDown={(keyboardEvent) => { if (keyboardEvent.key === "Enter") setSelection(event.id); }}><td>{formatDateTime(event.at, timeZone)}</td><td><strong>{event.label}</strong></td><td>{event.object}</td><td className="event-value-cell">{event.detail || "—"}</td><td>{event.actor}</td><td><span className={`state-label ${event.status === "synced" ? "success" : "warning"}`}>{event.status === "synced" ? "已同步" : "浏览器草稿"}</span></td><td>{event.revision ? `#${event.revision}` : "—"}</td></tr>) : <tr><td colSpan="7"><div className="empty-state">没有匹配的事件。</div></td></tr>}
          </tbody></table></div>
          {selectedEvent ? <aside className="entity-detail-pane event-detail-pane"><button className="icon-button detail-close" type="button" onClick={() => setSelection(null)} aria-label="关闭详情"><X size={19} /></button><p className="eyebrow">EVENT DETAIL</p><h2>{selectedEvent.label}</h2><p className="detail-object">{selectedEvent.object}</p><p className="event-detail-summary">{selectedEvent.detail || "没有可展示的具体值"}</p>{selectedEvent.note ? <div className="event-note"><strong>备注</strong><p>{selectedEvent.note}</p></div> : null}<button className="secondary-button" onClick={()=>downloadFile(exportEventsCSV([selectedEvent],{timeZone}),eventExportFileName(workspace.farm.name,{scope:selectedEvent.scope,timeZone}))}>导出本条事件</button><dl>{(selectedEvent.fields ?? []).map((field) => <div key={`${field.label}-${field.value}`}><dt>{field.label}</dt><dd>{field.value}</dd></div>)}<div><dt>发生时间</dt><dd>{formatDateTime(selectedEvent.at, timeZone)}</dd></div><div><dt>操作人</dt><dd>{selectedEvent.actor}</dd></div><div><dt>同步状态</dt><dd>{selectedEvent.status === "synced" ? "已同步" : "浏览器草稿，未提交云端"}</dd></div><div><dt>修订</dt><dd>{selectedEvent.revision ? `#${selectedEvent.revision}` : "—"}</dd></div></dl></aside> : null}
        </div>
        <footer className="panel-footer">匹配 {rows.length} 条事件 · 第 {page+1} / {Math.max(1,Math.ceil(rows.length/100))} 页 <button className="text-button" disabled={!page} onClick={()=>setPage(p=>p-1)}>上一页</button><button className="text-button" disabled={(page+1)*100>=rows.length} onClick={()=>setPage(p=>p+1)}>下一页</button> · 导出包含全部筛选结果</footer>
      </section>
    </main>
  );
}
