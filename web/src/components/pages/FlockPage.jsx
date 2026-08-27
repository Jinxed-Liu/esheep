import { useMemo, useState } from "react";
import { MagnifyingGlass } from "@phosphor-icons/react/MagnifyingGlass";
import { SheepGlyph as Sheep } from "../DomainIcons.jsx";
import { formatDateTime, PageTop, ProjectionNotice, Segmented } from "./FeaturePageShared.jsx";

export default function FlockPage({ workspace, onCreateRecord }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const baseline = workspace.projectionCoverage?.baseline;
  const [view, setView] = useState("sheep");
  const [filter, setFilter] = useState("");
  const lowerFilter = filter.trim().toLowerCase();
  const sheepRows = useMemo(
    () => workspace.sheep.filter((sheep) =>
      [sheep.earTag, sheep.breed, sheep.pen, sheep.stage].some((value) =>
        String(value ?? "").toLowerCase().includes(lowerFilter),
      ),
    ),
    [lowerFilter, workspace.sheep],
  );
  const penRows = useMemo(
    () => workspace.pens.filter((pen) => pen.headCount > 0).filter((pen) =>
      [pen.name, pen.purpose, pen.status].some((value) =>
        String(value ?? "").toLowerCase().includes(lowerFilter),
      ),
    ),
    [lowerFilter, workspace.pens],
  );

  return (
    <main className="page feature-page">
      <PageTop
        title="羊群"
        description="按有效历史查看羊只、圈舍与当前生产状态。"
        actionLabel="新建羊只"
        onAction={() => onCreateRecord("addSheep")}
        icon={Sheep}
      />
      <section className="workspace-panel">
        <div className="workspace-toolbar">
          <Segmented
            items={[{ id: "sheep", label: "羊只" }, { id: "pens", label: "圈舍" }]}
            value={view}
            onChange={setView}
          />
          <label className="inline-search">
            <MagnifyingGlass size={18} />
            <input value={filter} onChange={(event) => setFilter(event.target.value)} placeholder="筛选耳号、品种或圈舍" />
          </label>
        </div>
        {workspace.mode === "cloud" && workspace.projectionCoverage?.incompleteSheep ? (
          <ProjectionNotice>
            当前在场数量保留云端有效状态（{workspace.metrics.activeSheep.toLocaleString("zh-CN")} 只）；{baseline?.status === "loaded" ? `紧凑基线已展开，仍有 ${workspace.projectionCoverage.incompleteSheep.toLocaleString("zh-CN")} 只在云端缺少耳号、品种或性别字段，因此显示“资料未展开”，不猜填旧值。` : `紧凑基线未能读取（${baseline?.reason || "未知原因"}），其中 ${workspace.projectionCoverage.incompleteSheep.toLocaleString("zh-CN")} 只资料不完整，暂不猜填旧值。`}
          </ProjectionNotice>
        ) : null}
        <div className="table-scroll">
          {view === "sheep" ? (
            <table className="data-table">
              <thead><tr><th>耳号</th><th>品种</th><th>性别</th><th>生产阶段</th><th>当前圈舍</th><th>最近体重</th><th>更新时间</th></tr></thead>
              <tbody>
                {sheepRows.map((sheep) => (
                  <tr key={sheep.id}>
                    <td><strong>{sheep.earTag}</strong></td><td>{sheep.breed}</td><td>{sheep.sex}</td>
                    <td><span className="status-text">{sheep.stage}</span></td><td>{sheep.pen}</td>
                    <td>{sheep.weight == null ? "—" : `${sheep.weight} kg`}</td><td>{formatDateTime(sheep.updatedAt, timeZone)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <table className="data-table">
              <thead><tr><th>圈舍</th><th>用途</th><th>在场羊只</th><th>状态</th><th>最近更新</th></tr></thead>
              <tbody>
                {penRows.map((pen) => (
                  <tr key={pen.id}>
                    <td><strong>{pen.name}</strong></td><td>{pen.purpose}</td><td>{pen.headCount ?? "—"}</td>
                    <td><span className={`state-label ${pen.status === "正常" ? "success" : "warning"}`}>{pen.status}</span></td>
                    <td>{formatDateTime(pen.updatedAt, timeZone)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
        <footer className="panel-footer">{view === "sheep" ? `当前显示 ${sheepRows.length} 条记录` : `当前显示 ${penRows.length} 个有羊圈舍`}</footer>
      </section>
    </main>
  );
}
