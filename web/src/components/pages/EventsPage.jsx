import { useState } from "react";
import { formatDateTime, PageTop, Segmented } from "./FeaturePageShared.jsx";

export default function EventsPage({ workspace }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const [type, setType] = useState("all");
  const rows = type === "all" ? workspace.events : workspace.events.filter((event) => event.type === type);
  return (
    <main className="page feature-page">
      <PageTop title="事件记录" description="审计、纠正、撤销和远端重放都以事件为事实来源。" />
      <section className="workspace-panel">
        <div className="workspace-toolbar">
          <Segmented items={[{ id: "all", label: "全部" }, { id: "weight", label: "称重" }, { id: "feed", label: "投喂" }, { id: "health", label: "健康" }, { id: "transfer", label: "转群" }]} value={type} onChange={setType} />
          <span className="toolbar-note">{rows.length} 条</span>
        </div>
        <div className="table-scroll">
          <table className="data-table"><thead><tr><th>发生时间</th><th>事件</th><th>对象</th><th>操作人</th><th>同步状态</th><th>修订</th></tr></thead>
            <tbody>{rows.map((event) => (
              <tr key={event.id}><td>{formatDateTime(event.at, timeZone)}</td><td><strong>{event.label}</strong></td><td>{event.object}</td><td>{event.actor}</td><td><span className={`state-label ${event.status === "synced" ? "success" : "warning"}`}>{event.status === "synced" ? "已同步" : "本地草稿"}</span></td><td>{event.revision ? `#${event.revision}` : "—"}</td></tr>
            ))}</tbody>
          </table>
        </div>
      </section>
    </main>
  );
}
