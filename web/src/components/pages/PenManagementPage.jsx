import { useEffect, useMemo, useRef, useState } from "react";
import { Barn } from "@phosphor-icons/react/Barn";
import { MagnifyingGlass } from "@phosphor-icons/react/MagnifyingGlass";
import { X } from "@phosphor-icons/react/X";
import { PageTop, Segmented, formatDateTime } from "./FeaturePageShared.jsx";
import { currentPenCount, penDeletionBlock, penMatchesScope, penPermissions, penScopes, penStatus, validatePenName } from "../../lib/penManagement.js";
import "./PenManagementPage.css";

const titles = { create: "新建羊舍", update: "编辑羊舍", delete: "安全删除羊舍" };
const sameID = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();

function PenActionDialog({ action, pen, initialDraft, workspace, onClose, onSubmit, onComplete }) {
  const dialog = useRef(null);
  const saved = initialDraft?.record.penDraft;
  const [draftID] = useState(() => initialDraft?.id ?? crypto.randomUUID());
  const [penID] = useState(() => saved?.penID ?? pen?.id ?? crypto.randomUUID());
  const [expected] = useState(() => saved?.expected ?? (pen ? { name: pen.name, note: pen.note, isActive: pen.isActive } : null));
  const [name, setName] = useState(saved?.name ?? pen?.name ?? "");
  const [note, setNote] = useState(saved?.note ?? pen?.note ?? "");
  const [reason, setReason] = useState(saved?.reason ?? "");
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState("");
  const [elapsed, setElapsed] = useState(0);
  const [sealed, setSealed] = useState(Boolean(initialDraft?.signed));
  const [error, setError] = useState("");
  const title = action === "setActive" ? pen.isActive ? "停用羊舍" : "重新启用羊舍" : titles[action];
  const editing = action === "create" || action === "update";
  let nameError = "";
  if (editing && name.trim()) {
    try { validatePenName(name, workspace.models.PenRecord, action === "update" ? penID : undefined); }
    catch (e) { nameError = e.message; }
  }
  useEffect(() => {
    const element = dialog.current;
    element.showModal();
    element.querySelector("input, textarea")?.focus();
    return () => element.close();
  }, []);
  useEffect(() => {
    if (!busy) return;
    const started = Date.now();
    const timer = setInterval(() => setElapsed(Math.floor((Date.now() - started) / 1000)), 1000);
    return () => clearInterval(timer);
  }, [busy]);
  async function submit(event) {
    event.preventDefault();
    setBusy(true); setError(""); setElapsed(0); setProgress("正在准备提交…");
    try {
      const result = await onSubmit({ sheet: "羊舍管理", values: { 操作: title, 羊舍名称: name, 备注: note, 删除原因: reason },
        penAction: action, penDraft: { penID, name, note, reason, expected, ...(action === "setActive" ? { isActive: saved?.isActive ?? !pen.isActive } : {}) } }, draftID, setProgress);
      onComplete({ ...result, action, penID });
    } catch (e) {
      setError(e.message || "提交未完成，请保留原始请求后重试。");
      if (e.signed) setSealed(true);
    } finally { setBusy(false); }
  }
  return <dialog ref={dialog} className="record-dialog pen-action-dialog" aria-labelledby="pen-action-title" onCancel={event => { event.preventDefault(); if (!busy) onClose(); }}>
    <header><span><h2 id="pen-action-title">{title}</h2><p>{editing ? "名称在当前牧场内保持唯一；已停用羊舍也占用名称。" : `操作对象：${pen.name}`}</p></span><button className="icon-button" type="button" disabled={busy} onClick={onClose} aria-label="关闭羊舍操作"><X size={22} /></button></header>
    <form onSubmit={submit}>
      {editing ? <div className="form-grid">
        <label className="record-field"><span id="pen-name-label">羊舍名称 *</span><input aria-labelledby="pen-name-label" aria-describedby={nameError ? "pen-name-error" : undefined} required value={name} readOnly={sealed} disabled={busy} onChange={e => setName(e.target.value)} placeholder="例如：育肥三舍" />{nameError ? <small id="pen-name-error" className="form-error" role="alert">{nameError}</small> : null}</label>
        <label className="record-field"><span>备注 / 用途</span><textarea rows={3} value={note} readOnly={sealed} disabled={busy} onChange={e => setNote(e.target.value)} placeholder="可填写用途或管理说明" /></label>
      </div> : action === "delete" ? <>
        <p>仅可删除没有关联业务和历史记录的羊舍。删除后会从正常列表移除，删除原因和审计记录仍会保留，云端会再次核对条件。</p>
        <label className="record-field"><span>删除原因 *</span><textarea autoFocus required rows={3} value={reason} readOnly={sealed} disabled={busy} onChange={e => setReason(e.target.value)} placeholder="请填写本次删除的原因" /></label>
      </> : <p>{pen.isActive ? "停用后不能再选择此羊舍进行新增业务，已有历史记录保留。需要继续使用时，可以重新启用。" : "重新启用后，此羊舍可以再次用于新增业务，历史记录保持不变。"}</p>}
      {sealed ? <p className="pen-help">原始提交已保存。重试将核对同一份请求；可在“录入”的草稿与回执中继续查看。</p> : null}
      {busy ? <p className="pen-help" role="status">{progress}{elapsed > 0 ? ` 已用 ${elapsed} 秒` : ""}</p> : null}
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <footer><button className="secondary-button" type="button" disabled={busy} onClick={onClose}>取消</button><button className={action === "delete" ? "secondary-button pen-danger" : "primary-button"} disabled={busy || !sealed && (editing ? !name.trim() || Boolean(nameError) : action === "delete" && !reason.trim())}>{busy ? "正在核对并提交…" : sealed ? "核对原始提交" : action === "delete" ? "确认安全删除" : editing ? "保存到云端" : `确认${title}`}</button></footer>
    </form>
  </dialog>;
}

export default function PenManagementPage({ workspace, selectedID, initialScope = "all", resumeDraft, onSubmit, onShowSheep, onNavigate, onCreateRecord }) {
  const [scope, setScope] = useState(initialScope);
  const [search, setSearch] = useState("");
  const [selection, setSelection] = useState(selectedID ?? null);
  const [action, setAction] = useState(null);
  const [notice, setNotice] = useState(null);
  const detail = useRef(null);
  const permissions = penPermissions(workspace);
  const timeZone = workspace.farm.timeZoneIdentifier || "Asia/Shanghai";
  useEffect(() => { setScope(initialScope); }, [initialScope]);
  useEffect(() => { if (selectedID) { setSelection(selectedID); setScope("all"); setSearch(""); } }, [selectedID]);
  const pens = useMemo(() => workspace.pens.map(pen => {
    const raw = workspace.models?.PenRecord?.find(p => sameID(p.id, pen.id));
    return { ...pen, ...(raw ? { name: raw.name, note: raw.note, isActive: raw.isActive } : {}),
      isActive: raw?.isActive ?? pen.isActive ?? pen.status !== "停用" };
  }), [workspace.pens, workspace.models]);
  useEffect(() => {
    if (!resumeDraft) return;
    const draft = resumeDraft.record.penDraft;
    setAction({ type: resumeDraft.record.penAction, initialDraft: resumeDraft,
      pen: { id: draft.penID, ...draft.expected, name: draft.expected?.name ?? draft.name } });
  }, [resumeDraft]);
  const selected = pens.find(p => sameID(p.id, selection));
  useEffect(() => {
    if (selection && window.matchMedia("(max-width: 800px)").matches) detail.current?.scrollIntoView({ block: "start" });
  }, [selection]);
  const rows = pens.filter(p => penMatchesScope(p, scope) && `${p.name} ${p.note ?? p.purpose ?? ""} ${penStatus(p)}`.toLowerCase().includes(search.trim().toLowerCase()));
  const counts = Object.fromEntries(penScopes.map(item => [item.id, pens.filter(p => penMatchesScope(p, item.id)).length]));
  const deletionBlock = selected ? penDeletionBlock(workspace, selected) : "";
  const occupied = selected && permissions.ready ? currentPenCount(workspace.models, selected.id, workspace.farm.id) > 0 : true;
  function completed(result) {
    setAction(null); setScope("all"); setSearch("");
    setSelection(result.action === "delete" ? null : result.penID);
    setNotice({ pending: result.refreshed === false, message: result.refreshed === false
      ? "云端已接受本次操作，但资料刷新尚未完成。请刷新页面核对，勿重复新建。"
      : "云端已接受本次操作，羊舍资料已刷新。" });
  }
  return <main className="page feature-page pen-management-page">
    <PageTop title="羊舍管理" description="查看全部羊舍，维护名称、备注和启用状态。空舍可以继续使用。" actionLabel={permissions.edit ? "新建羊舍" : undefined} onAction={() => setAction({ type: "create", pen: null })} />
    {notice ? <p className={`pen-feedback ${notice.pending ? "warning" : "success"}`} role="status">{notice.message}</p> : null}
    {!permissions.ready ? <p className="pen-help">完整牧场资料尚未读取，当前仅可查看。</p> : !permissions.edit ? <p className="pen-help">当前账号仅可查看羊舍，编辑需要牧场记录权限。</p> : null}
    <section className="workspace-panel entity-workspace">
      <div className="workspace-toolbar"><Segmented items={[{ id: "sheep", label: "羊只" }, { id: "pens", label: "羊舍管理" }]} value="pens" onChange={value => { if (value === "sheep") onShowSheep(); }} /><label className="inline-search"><MagnifyingGlass size={18} /><input aria-label="搜索羊舍" value={search} onChange={e => setSearch(e.target.value)} placeholder="搜索名称、备注或状态" /></label></div>
      <div className="workspace-toolbar pen-scopes"><Segmented items={penScopes.map(item => ({ ...item, label: `${item.label} ${counts[item.id]}` }))} value={scope} onChange={setScope} /><span className="pen-help">共 {pens.length} 个羊舍 · 有羊 {counts.occupied} 个</span></div>
      <div className={`entity-content ${selected ? "with-detail" : ""}`}>
        <div className="table-scroll"><table className="data-table selectable-table">
          <thead><tr><th>羊舍名称</th><th>备注 / 用途</th><th>当前羊只</th><th>状态</th><th>最近更新</th></tr></thead>
          <tbody>{rows.length ? rows.map(pen => <tr key={pen.id} tabIndex={0} aria-label={`查看羊舍 ${pen.name}`} aria-selected={selection === pen.id} className={selection === pen.id ? "selected" : ""} onClick={() => setSelection(pen.id)} onKeyDown={event => { if (["Enter", " "].includes(event.key)) { event.preventDefault(); setSelection(pen.id); } }}>
            <td><strong>{pen.name}</strong></td><td>{pen.note || "未填写"}</td><td>{pen.headCount ?? "—"} 只</td><td><span className={`state-label ${pen.isActive ? "success" : "warning"}`}>{penStatus(pen)}</span></td><td>{formatDateTime(pen.updatedAt, timeZone)}</td>
          </tr>) : <tr><td colSpan={5}><div className="empty-state">{pens.length ? "没有符合条件的羊舍，可切换筛选或清空搜索。" : "还没有羊舍，点击“新建羊舍”建立第一个羊舍。"}</div></td></tr>}</tbody>
        </table></div>
        {selected ? <aside ref={detail} className="entity-detail-pane">
          <button className="icon-button detail-close" type="button" aria-label="关闭详情" onClick={() => setSelection(null)}><X size={19} /></button>
          <span className="detail-hero-icon"><Barn size={27} /></span><p className="eyebrow">羊舍档案</p><h2>{selected.name}</h2>
          <dl><div><dt>当前羊只</dt><dd>{selected.headCount ?? "—"} 只</dd></div><div><dt>状态</dt><dd>{penStatus(selected)}</dd></div><div><dt>备注 / 用途</dt><dd>{selected.note || "未填写"}</dd></div><div><dt>最近更新</dt><dd>{formatDateTime(selected.updatedAt, timeZone)}</dd></div></dl>
          <div className="pen-management-actions">
            {permissions.edit ? <button className="primary-button" onClick={() => setAction({ type: "update", pen: selected })}>编辑羊舍</button> : null}
            {permissions.lifecycle ? <><button className="secondary-button" disabled={selected.isActive && occupied} onClick={() => setAction({ type: "setActive", pen: selected })}>{selected.isActive ? "停用羊舍" : "重新启用"}</button><button className="secondary-button pen-danger" disabled={Boolean(deletionBlock)} onClick={() => setAction({ type: "delete", pen: selected })}>安全删除</button></> : <p className="pen-help">停用、启用和删除仅限牧场主或管理员。</p>}
          </div>
          {selected.isActive && occupied ? <p className="pen-help">羊舍中仍有羊只，完成转群后才能停用。</p> : null}
          {deletionBlock ? <p className="pen-help">{deletionBlock}</p> : <p className="pen-help">删除前需填写原因并确认，云端会再次检查历史关联。</p>}
          {selected.isActive && permissions.edit ? <div className="detail-actions"><button className="secondary-button" onClick={() => onCreateRecord("feed", { values: { 圈舍: selected.name } })}>记录投喂</button></div> : null}
        </aside> : null}
      </div>
      <footer className="panel-footer">当前显示 {rows.length} 个羊舍 · 历史业务记录会保留<button type="button" className="text-button" onClick={() => onNavigate?.("entry")}>查看提交与回执</button></footer>
    </section>
    {action ? <PenActionDialog action={action.type} pen={action.pen} initialDraft={action.initialDraft} workspace={workspace} onClose={() => setAction(null)} onSubmit={onSubmit} onComplete={completed} /> : null}
  </main>;
}
