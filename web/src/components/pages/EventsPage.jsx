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
  const [type, setType] = useState("all");
  const [query, setQuery] = useState("");
  const [selection, setSelection] = useState(selectedID ?? null);
  useEffect(() => {
    if (selectedID) setSelection(selectedID);
  }, [selectedID]);
  const rows = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return workspace.events
      .filter((event) => type === "all" || event.type === type)
      .filter((event) => !needle || [event.label, event.object, event.detail, event.note, event.actor, eventFieldText(event)].some((value) => String(value ?? "").toLowerCase().includes(needle)));
  }, [query, type, workspace.events]);
  const selectedEvent = workspace.events.find((event) => event.id === selection);

  function exportCSV() {
    const header = ["发生时间", "事件", "对象", "具体值", "备注", "业务字段", "操作人", "同步状态", "修订"];
    const lines = [header, ...rows.map((event) => [event.at, event.label, event.object, event.detail, event.note, eventFieldText(event), event.actor, event.status === "synced" ? "已同步" : "本地草稿", event.revision ?? ""])].map((line) => line.map(csvCell).join(","));
    const blob = new Blob([`\ufeff${lines.join("\n")}`], { type: "text/csv;charset=utf-8" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = `eSheepPlus-${workspace.farm.name}-事件记录.csv`;
    link.click();
    URL.revokeObjectURL(link.href);
  }

  return (
    <main className="page feature-page">
      <PageTop title="事件历史" description="按发生时间保留业务事实、修订和同步状态；可筛选、查看详情并导出当前结果。" actionLabel="导出当前结果" onAction={exportCSV} icon={DownloadSimple} />
      {exportHint ? <div className="export-hint">已从首页进入导出：先检查筛选结果，再点击“导出当前结果”。</div> : null}
      <section className="workspace-panel entity-workspace">
        <div className="workspace-toolbar event-toolbar">
          <Segmented items={[{ id: "all", label: "全部" }, { id: "weight", label: "称重" }, { id: "feed", label: "投喂" }, { id: "health", label: "健康" }, { id: "transfer", label: "转群" }, { id: "reproduction", label: "繁殖" }]} value={type} onChange={setType} />
          <label className="inline-search"><MagnifyingGlass size={18} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="搜索耳号、重量、原因、圈舍或备注" /></label>
        </div>
        <div className={`entity-content ${selectedEvent ? "with-detail" : ""}`}>
          <div className="table-scroll"><table className="data-table selectable-table event-data-table"><thead><tr><th>发生时间</th><th>事件</th><th>对象</th><th>具体值</th><th>操作人</th><th>同步状态</th><th>修订</th></tr></thead><tbody>
            {rows.length ? rows.map((event) => <tr className={selection === event.id ? "selected" : ""} key={event.id} tabIndex="0" onClick={() => setSelection(event.id)} onKeyDown={(keyboardEvent) => { if (keyboardEvent.key === "Enter") setSelection(event.id); }}><td>{formatDateTime(event.at, timeZone)}</td><td><strong>{event.label}</strong></td><td>{event.object}</td><td className="event-value-cell">{event.detail || "—"}</td><td>{event.actor}</td><td><span className={`state-label ${event.status === "synced" ? "success" : "warning"}`}>{event.status === "synced" ? "已同步" : "浏览器草稿"}</span></td><td>{event.revision ? `#${event.revision}` : "—"}</td></tr>) : <tr><td colSpan="7"><div className="empty-state">没有匹配的事件。</div></td></tr>}
          </tbody></table></div>
          {selectedEvent ? <aside className="entity-detail-pane event-detail-pane"><button className="icon-button detail-close" type="button" onClick={() => setSelection(null)} aria-label="关闭详情"><X size={19} /></button><p className="eyebrow">EVENT DETAIL</p><h2>{selectedEvent.label}</h2><p className="detail-object">{selectedEvent.object}</p><p className="event-detail-summary">{selectedEvent.detail || "没有可展示的具体值"}</p>{selectedEvent.note ? <div className="event-note"><strong>备注</strong><p>{selectedEvent.note}</p></div> : null}<dl>{(selectedEvent.fields ?? []).map((field) => <div key={`${field.label}-${field.value}`}><dt>{field.label}</dt><dd>{field.value}</dd></div>)}<div><dt>发生时间</dt><dd>{formatDateTime(selectedEvent.at, timeZone)}</dd></div><div><dt>操作人</dt><dd>{selectedEvent.actor}</dd></div><div><dt>同步状态</dt><dd>{selectedEvent.status === "synced" ? "已同步" : "浏览器草稿，未提交云端"}</dd></div><div><dt>修订</dt><dd>{selectedEvent.revision ? `#${selectedEvent.revision}` : "—"}</dd></div></dl></aside> : null}
        </div>
        <footer className="panel-footer">当前显示 {rows.length} 条事件</footer>
      </section>
    </main>
  );
}
