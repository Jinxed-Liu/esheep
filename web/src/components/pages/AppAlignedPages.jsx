import { useDeferredValue, useEffect, useMemo, useState } from "react";
import { Barn } from "@phosphor-icons/react/Barn";
import { CaretRight } from "@phosphor-icons/react/CaretRight";
import { Factory } from "@phosphor-icons/react/Factory";
import { FirstAidKit } from "@phosphor-icons/react/FirstAidKit";
import { MagnifyingGlass } from "@phosphor-icons/react/MagnifyingGlass";
import { Package } from "@phosphor-icons/react/Package";
import { Syringe } from "@phosphor-icons/react/Syringe";
import { Tag } from "@phosphor-icons/react/Tag";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";
import { PageTop, ProjectionNotice, Segmented } from "./FeaturePageShared.jsx";

const kindMeta = {
  sheep: { label: "羊只", icon: Tag },
  pen: { label: "圈舍", icon: Barn },
  event: { label: "事件", icon: FirstAidKit },
};

export function SearchPage({ searchIndex, onOpenResult }) {
  const [query, setQuery] = useState("");
  const [limit,setLimit]=useState(100);
  const [kind, setKind] = useState("all");
  const deferredQuery = useDeferredValue(query);
  const results = useMemo(() => {
    const needle = deferredQuery.trim().toLowerCase();
    return searchIndex.filter((item) => {
      const kindMatches = kind === "all" || item.kind === kind;
      return kindMatches && (!needle || item.haystack.includes(needle));
    });
  }, [deferredQuery, kind, searchIndex]);

  return (
    <main className="page feature-page search-page">
      <PageTop title="搜索" description="按耳号、品种、圈舍、事件或操作人统一查找；结果会打开对应的 App 业务位置。" />
      <section className="search-workspace">
        <label className="search-hero-field">
          <MagnifyingGlass size={26} />
          <input autoFocus value={query} onChange={(event) => setQuery(event.target.value)} placeholder="输入耳号、圈舍名称或事件…" />
          {query ? <button type="button" onClick={() => setQuery("")}>清空</button> : null}
        </label>
        <div className="search-filter-row">
          <Segmented items={[{ id: "all", label: "全部" }, { id: "sheep", label: "羊只" }, { id: "pen", label: "圈舍" }, { id: "event", label: "事件" }]} value={kind} onChange={setKind} />
          <span>{results.length} 条结果</span>
        </div>
        <div className="search-result-list">
          {results.length ? results.slice(0,limit).map((result) => {
            const meta = kindMeta[result.kind];
            const Icon = meta.icon;
            return (
              <button type="button" key={`${result.kind}-${result.id}`} onClick={() => onOpenResult(result)}>
                <span className="search-kind-icon"><Icon size={22} /></span>
                <span><small>{meta.label}</small><strong>{result.title}</strong><p>{result.detail}</p></span>
                <CaretRight size={20} weight="bold" />
              </button>
            );
          }) : (
            <div className="open-empty-state search-empty"><strong>没有匹配结果</strong><span>换一个耳号、圈舍或事件关键词试试。</span></div>
          )}
        </div>
        {results.length>limit?<button className="secondary-button" onClick={()=>setLimit(l=>l+100)}>继续显示 · 还有 {results.length-limit} 条</button>:null}
      </section>
    </main>
  );
}

export function AlertsPage({ workspace, selectedID, onNavigate, onCreateRecord }) {
  const [selected, setSelected] = useState(selectedID ?? workspace.alerts?.[0]?.id ?? null);
  useEffect(() => {
    if (selectedID) setSelected(selectedID);
  }, [selectedID]);
  const selectedAlert = workspace.alerts?.find((alert) => alert.id === selected);

  function resolveAlert(alert) {
    if (alert.action) onCreateRecord(alert.action);
    else if (alert.id === "weaning") onCreateRecord("weaning");
    else if (alert.id === "pregnancy") onCreateRecord("reproduction");
    else onNavigate("pens");
  }

  return (
    <main className="page feature-page">
      <PageTop title="待办与异常" description="与 App 首页使用同一业务分组；每条规则说明口径并回到可处理的业务入口。" />
      {!workspace.alertRulesConfigured ? <ProjectionNotice>尚未配置日常异常规则。可在“录入 → 全部录入类型 → 提醒规则”设置；已有护理提醒仍会显示。</ProjectionNotice> : null}
      {workspace.alerts?.length ? (
        <div className="master-detail-layout">
          <section className="master-list">
            {workspace.alerts.map((alert) => (
              <button className={selected === alert.id ? "active" : ""} type="button" key={alert.id} onClick={() => setSelected(alert.id)}>
                <WarningCircle className={`tone-${alert.tone}`} size={25} weight="fill" />
                <span><strong>{alert.title}</strong><small>{alert.description}</small></span>
                <b>{alert.count}{alert.unit}</b>
              </button>
            ))}
          </section>
          <aside className="detail-pane">
            {selectedAlert ? (
              <>
                <p className="eyebrow">RULE DETAIL</p>
                <h2>{selectedAlert.title}</h2>
                <div className="detail-emphasis">{selectedAlert.count}<small>{selectedAlert.unit}</small></div>
                <p>{selectedAlert.description}</p>
                <dl><div><dt>数据范围</dt><dd>当前牧场有效事件</dd></div><div><dt>处理原则</dt><dd>打开原业务记录，不直接改写历史</dd></div></dl>
                <button className="primary-button" type="button" onClick={() => resolveAlert(selectedAlert)}>前往处理 <CaretRight size={18} /></button>
              </>
            ) : null}
          </aside>
        </div>
      ) : <div className="open-empty-state page-empty"><strong>当前没有到期的待办或异常</strong><span>按牧场已保存的规则和有效记录计算。</span></div>}
    </main>
  );
}

export function CarePage({ workspace, onCreateRecord }) {
  const items = workspace.careItems ?? [];
  const lowStockCount = items.filter((item) => Number(item.stock) <= 0 || item.expired).length;
  return (
    <main className="page feature-page">
      <PageTop title="护理管理" description="治疗、疫苗、驱虫与护理库存集中管理；业务记录仍进入统一事件历史。" actionLabel="记录治疗 / 疫苗" onAction={() => onCreateRecord("health")} icon={FirstAidKit} />
      <div className="workspace-toolbar"><button className="secondary-button" onClick={()=>onCreateRecord("库存入库")}>库存入库</button><button className="secondary-button" onClick={()=>onCreateRecord("库存调整")}>库存调整</button><button className="secondary-button" onClick={()=>onCreateRecord("健康目录")}>维护健康目录</button></div>
      <section className="summary-strip">
        <article><FirstAidKit size={24} /><span><small>护理项目</small><strong>{items.length}<em>项</em></strong></span></article>
        <article><WarningCircle size={24} /><span><small>缺货或过期</small><strong>{lowStockCount}<em>项</em></strong></span></article>
        <article><Syringe size={24} /><span><small>健康事件</small><strong>{workspace.events.filter((event) => event.type === "health").length}<em>条</em></strong></span></article>
      </section>
      <section className="workspace-panel flat-panel">
        <div className="panel-heading"><h2>药品与疫苗目录</h2><span>{items.length} 项</span></div>
        <div className="table-scroll"><table className="data-table"><thead><tr><th>名称</th><th>分类</th><th>当前库存</th><th>批号 / 有效期</th><th>状态</th></tr></thead><tbody>
          {items.length ? items.map((item) => <tr key={item.id}><td><strong>{item.name}</strong></td><td>{item.category}</td><td>{item.stock} {item.unit}</td><td>{item.batchNumber} / {item.expiresAt?new Date(item.expiresAt).toLocaleDateString("zh-CN"):"未设"}</td><td><span className={`state-label ${Number(item.stock) <= 0 || item.expired ? "warning" : "success"}`}>{Number(item.stock) <= 0 || item.expired ? "需核对" : "可用"}</span></td></tr>) : <tr><td colSpan="5"><div className="empty-state">暂无可读取的护理库存。</div></td></tr>}
        </tbody></table></div>
      </section>
      <section className="workspace-panel flat-panel"><h2>健康目录</h2><div className="table-scroll"><table className="data-table"><thead><tr><th>名称</th><th>类型</th><th>默认剂量</th><th>给药途径</th><th>状态</th></tr></thead><tbody>{workspace.models?.HealthCatalogItemRecord?.filter(r=>r.deletedAt==null).map(r=><tr key={r.id}><td>{r.name}</td><td>{r.kindRawValue==="vaccination"?"疫苗":"治疗"}</td><td>{r.defaultDoseText??"未设"} {r.unit}</td><td>{r.defaultRoute||"未设"}</td><td>{r.isActive?"启用":"停用"}</td></tr>)}</tbody></table></div></section>
      <section className="workspace-panel flat-panel"><div className="panel-heading"><h2>冻精库存</h2><button className="secondary-button" onClick={()=>onCreateRecord("冻精入库")}>冻精入库</button></div><div className="table-scroll"><table className="data-table"><thead><tr><th>编号</th><th>品种</th><th>批号</th><th>可用数量</th></tr></thead><tbody>{workspace.semenInventory?.map(r=><tr key={r.id}><td>{r.code}</td><td>{r.breed}</td><td>{r.batchNumber}</td><td>{r.balance}</td></tr>)}</tbody></table></div></section>
    </main>
  );
}

export function ProductionBatchesPage({ workspace,onCreateRecord }) {
  const batches = workspace.batches ?? [];
  return (
    <main className="page feature-page">
      <PageTop title="生产批次" description="按批次组织育肥、后备与产羔管理，保持圈舍和羊只事实可追溯。" />
      <div className="workspace-toolbar"><button className="primary-button" onClick={()=>onCreateRecord("生产批次")}>新建生产批次</button><button className="secondary-button" onClick={()=>onCreateRecord("批次脱离")}>记录批次脱离</button></div>
      <section className="workspace-panel flat-panel">
        <div className="panel-heading"><h2>批次列表</h2><Factory size={24} /></div>
        <div className="table-scroll"><table className="data-table"><thead><tr><th>批次</th><th>阶段</th><th>圈舍</th><th>羊只</th><th>开始日期</th><th>状态</th></tr></thead><tbody>
          {batches.length ? batches.map((batch) => <tr key={batch.id}><td><strong>{batch.name}</strong><details><summary>查看成员</summary>{batch.members?.map(m=><span key={m.id}>{m.earTag}　</span>)}</details></td><td>{batch.stage}</td><td>{batch.penCount} 个</td><td>{batch.sheepCount} 只</td><td>{batch.startDate}</td><td><span className={`state-label ${batch.status === "进行中" ? "success" : "neutral"}`}>{batch.status}</span></td></tr>) : <tr><td colSpan="6"><div className="empty-state">暂无可读取的生产批次。</div></td></tr>}
        </tbody></table></div>
      </section>
      <section className="batch-guidance"><Package size={24} /><span><strong>批次不等于圈舍</strong><small>批次负责管理目标，圈舍负责当前物理位置；网页端会保持两条事实链分离。</small></span></section>
    </main>
  );
}
