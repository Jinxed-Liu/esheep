import { useState } from "react";
import { BowlFood } from "@phosphor-icons/react/BowlFood";
import { formatDateTime, PageTop, ProjectionNotice, Segmented } from "./FeaturePageShared.jsx";

export default function FeedingPage({ workspace, onCreateRecord }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  const [tab, setTab] = useState("records");
  return (
    <main className="page feature-page">
      <PageTop title="投喂" description="原料、配方、批次与投喂历史使用同一营养快照链路。" actionLabel="记录投喂" onAction={() => onCreateRecord("feed")} icon={BowlFood} />
      <section className="workspace-panel">
        <div className="workspace-toolbar">
          <Segmented
            items={[{ id: "records", label: "投喂记录" }, { id: "ingredients", label: "原料库" }, { id: "recipes", label: "配方" }]}
            value={tab}
            onChange={setTab}
          />
          <span className="toolbar-note">顿次统一为：早 / 中 / 晚 / 全天</span>
        </div>
        {workspace.mode === "cloud" ? <ProjectionNotice>投喂、原料与配方均读取云端基础投影；库存数量、营养计算与 TMR 监控尚未接入，因此不会显示演示数值。方式已按 App 语义显示为“限量投喂 / 自由采食”。</ProjectionNotice> : null}
        <div className="table-scroll">
          {tab === "records" ? (
            <table className="data-table">
              <thead><tr><th>发生时间</th><th>圈舍</th><th>顿次</th><th>配方</th><th>方式</th><th>投喂量</th><th>干物质</th></tr></thead>
              <tbody>{workspace.feedRecords.length ? workspace.feedRecords.map((record) => (
                <tr key={record.id}><td>{formatDateTime(record.at, timeZone)}</td><td><strong>{record.pen}</strong></td><td>{record.meal}</td><td>{record.recipe}</td><td>{record.mode}</td><td>{record.kilograms.toLocaleString("zh-CN")} kg</td><td>{record.dryMatter == null ? "—" : `${record.dryMatter.toLocaleString("zh-CN", { maximumFractionDigits: 1 })} kg`}</td></tr>
              )) : <tr><td colSpan="7"><div className="empty-state">暂无云端投喂记录。</div></td></tr>}</tbody>
            </table>
          ) : null}
          {tab === "ingredients" ? (
            <table className="data-table">
              <thead><tr><th>原料</th><th>类别</th><th>单位</th><th>干物质</th><th>可用库存</th></tr></thead>
              <tbody>{workspace.ingredients.length ? workspace.ingredients.map((item) => (
                <tr key={item.id}><td><strong>{item.name}</strong></td><td>{item.category}</td><td>{item.unit}</td><td>{item.dryMatter == null ? "—" : `${item.dryMatter}%`}</td><td>{item.stock == null ? "—" : `${item.stock.toLocaleString("zh-CN")} kg`}</td></tr>
              )) : <tr><td colSpan="5"><div className="empty-state">暂无云端原料目录。</div></td></tr>}</tbody>
            </table>
          ) : null}
          {tab === "recipes" ? (
            <table className="data-table">
              <thead><tr><th>配方</th><th>适用阶段</th><th>基准重量</th><th>CP</th><th>ME</th><th>NDF</th></tr></thead>
              <tbody>{workspace.recipes.length ? workspace.recipes.map((recipe) => (
                <tr key={recipe.id}><td><strong>{recipe.name}</strong></td><td>{recipe.stage}</td><td>{recipe.totalKg.toLocaleString("zh-CN")} kg</td><td>{recipe.cp == null ? "—" : `${recipe.cp}%`}</td><td>{recipe.me == null ? "—" : `${recipe.me} MJ/kg`}</td><td>{recipe.ndf == null ? "—" : `${recipe.ndf}%`}</td></tr>
              )) : <tr><td colSpan="6"><div className="empty-state">暂无云端配方。</div></td></tr>}</tbody>
            </table>
          ) : null}
        </div>
      </section>
    </main>
  );
}
