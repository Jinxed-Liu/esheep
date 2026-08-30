import { useEffect, useMemo, useState } from "react";
import { Barn } from "@phosphor-icons/react/Barn";
import { MagnifyingGlass } from "@phosphor-icons/react/MagnifyingGlass";
import { Scales } from "@phosphor-icons/react/Scales";
import { Tag } from "@phosphor-icons/react/Tag";
import { X } from "@phosphor-icons/react/X";
import { formatDateTime, PageTop, ProjectionNotice, Segmented } from "./FeaturePageShared.jsx";

export default function FlockPage({ workspace, initialView = "sheep", selectedID, onCreateRecord }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const baseline = workspace.projectionCoverage?.baseline;
  const [view, setView] = useState(initialView);
  const [filter, setFilter] = useState("");
  const [selection, setSelection] = useState(selectedID ?? null);

  useEffect(() => setView(initialView), [initialView]);
  useEffect(() => {
    if (selectedID) setSelection(selectedID);
  }, [selectedID]);

  const lowerFilter = filter.trim().toLowerCase();
  const sheepRows = useMemo(
    () => workspace.sheep.filter((sheep) => [sheep.earTag, sheep.breed, sheep.pen, sheep.stage].some((value) => String(value ?? "").toLowerCase().includes(lowerFilter))),
    [lowerFilter, workspace.sheep],
  );
  const penRows = useMemo(
    () => workspace.pens.filter((pen) => (pen.headCount ?? 0) > 0).filter((pen) => [pen.name, pen.purpose, pen.status].some((value) => String(value ?? "").toLowerCase().includes(lowerFilter))),
    [lowerFilter, workspace.pens],
  );
  const selectedEntity = view === "sheep"
    ? workspace.sheep.find((sheep) => sheep.id === selection)
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
        <div className={`entity-content ${selectedEntity ? "with-detail" : ""}`}>
          <div className="table-scroll">
            {view === "sheep" ? (
              <table className="data-table selectable-table">
                <thead><tr><th>耳号</th><th>品种</th><th>性别</th><th>生产阶段</th><th>当前圈舍</th><th>最近体重</th><th>更新时间</th></tr></thead>
                <tbody>{sheepRows.length ? sheepRows.map((sheep) => (
                  <tr className={selection === sheep.id ? "selected" : ""} key={sheep.id} tabIndex="0" onClick={() => setSelection(sheep.id)} onKeyDown={(event) => { if (event.key === "Enter") setSelection(sheep.id); }}>
                    <td><strong>{sheep.earTag}</strong></td><td>{sheep.breed}</td><td>{sheep.sex}</td><td><span className="status-text">{sheep.stage}</span></td><td>{sheep.pen}</td><td>{sheep.weight == null ? "—" : `${sheep.weight} kg`}</td><td>{formatDateTime(sheep.updatedAt, timeZone)}</td>
                  </tr>
                )) : <tr><td colSpan="7"><div className="empty-state">没有匹配的羊只。</div></td></tr>}</tbody>
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
              <span className="detail-hero-icon">{view === "sheep" ? <Tag size={27} /> : <Barn size={27} />}</span>
              <p className="eyebrow">{view === "sheep" ? "SHEEP PROFILE" : "PEN PROFILE"}</p>
              <h2>{view === "sheep" ? selectedEntity.earTag : selectedEntity.name}</h2>
              {view === "sheep" ? (
                <>
                  <dl><div><dt>品种 / 性别</dt><dd>{selectedEntity.breed} · {selectedEntity.sex}</dd></div><div><dt>当前圈舍</dt><dd>{selectedEntity.pen}</dd></div><div><dt>生产阶段</dt><dd>{selectedEntity.stage}</dd></div><div><dt>最近体重</dt><dd>{selectedEntity.weight == null ? "—" : `${selectedEntity.weight} kg`}</dd></div><div><dt>更新时间</dt><dd>{formatDateTime(selectedEntity.updatedAt, timeZone)}</dd></div></dl>
                  <div className="detail-actions"><button className="primary-button" type="button" onClick={() => onCreateRecord("weight")}><Scales size={18} />记录称重</button><button className="secondary-button" type="button" onClick={() => onCreateRecord("transfer")}>转群</button></div>
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
    </main>
  );
}
