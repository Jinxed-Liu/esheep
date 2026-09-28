import { lazy, Suspense, useCallback, useEffect, useMemo, useState, useTransition } from "react";
import { CheckCircle } from "@phosphor-icons/react/CheckCircle";
import { SpinnerGap } from "@phosphor-icons/react/SpinnerGap";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";
import { X } from "@phosphor-icons/react/X";
import { AppHeader } from "./components/AppHeader.jsx";
import { HomeDashboard } from "./components/HomeDashboard.jsx";
import { InviteOnlyAccessScreen } from "./components/InviteOnlyAccessScreen.jsx";
import { CloudAccessErrorScreen } from "./components/CloudAccessErrorScreen.jsx";
import { LoginScreen } from "./components/LoginScreen.jsx";
import { listDrafts, saveDraft, discardDraft } from "./lib/draftStore.js";
import { submitDraft } from "./lib/cloudV2Writes.js";
import { buildBusinessCommands } from "./lib/businessCommands.js";
import { isSupabaseConfigured } from "./lib/supabaseConfig.js";
import { cloudAccessErrorMessage, loadWithTransientJWTClockRetry } from "./lib/cloudReadRecovery.js";
import {
  WorkspaceDataSource,
  workspaceHasSections,
  workspaceSectionsForPage,
} from "./lib/workspaceDataSource.js";

import { reportCloudReadProgress, subscribeCloudReadProgress } from "./lib/cloudReadProgress.js";

let supabaseModulePromise;

function loadSupabaseModule() {
  supabaseModulePromise ??= import("./lib/supabase.js");
  return supabaseModulePromise;
}

const workspaceDataSource = new WorkspaceDataSource({
  loadWorkspace: async (farmID, options) => {
    const cloud = await loadSupabaseModule();
    return loadWithTransientJWTClockRetry(
      () => cloud.loadCloudWorkspace(farmID, { ...options, onProgress: (message) => reportCloudReadProgress(message, options?.signal) }),
      { signal: options?.signal },
    );
  },
});

const EntryPage = lazy(() => import("./components/pages/EntryPage.jsx"));
const EventsPage = lazy(() => import("./components/pages/EventsPage.jsx"));
const FeedingPage = lazy(() => import("./components/pages/FeedingPage.jsx"));
const FlockPage = lazy(() => import("./components/pages/FlockPage.jsx"));
const InsightsPage = lazy(() => import("./components/pages/InsightsPage.jsx"));
const AlertsPage = lazy(() => import("./components/pages/AppAlignedPages.jsx").then((module) => ({ default: module.AlertsPage })));
const CarePage = lazy(() => import("./components/pages/AppAlignedPages.jsx").then((module) => ({ default: module.CarePage })));
const ProductionBatchesPage = lazy(() => import("./components/pages/AppAlignedPages.jsx").then((module) => ({ default: module.ProductionBatchesPage })));
const SearchPage = lazy(() => import("./components/pages/AppAlignedPages.jsx").then((module) => ({ default: module.SearchPage })));
const RecordDialog = lazy(() => import("./components/RecordDialog.jsx").then((module) => ({ default: module.RecordDialog })));
const SettingsPage = lazy(() => import("./components/pages/SettingsPage.jsx"));
const TMRPage = lazy(() => import("./components/pages/TMRPage.jsx"));

function createID() {
  return globalThis.crypto?.randomUUID?.() ?? `web-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function explainAppleAuthError(error) {
  const rawMessage = String(error?.message ?? "");
  if (/missing oauth secret/i.test(rawMessage)) {
    return "Supabase 的 Apple Provider 尚未完成配置，请在 Auth → Providers → Apple 补齐 Apple Developer 生成的 OAuth Secret。";
  }
  if (/redirect/i.test(rawMessage)) {
    return "Apple 登录回调地址未加入 Supabase Redirect URLs，请把当前网页地址加入允许列表。";
  }
  return rawMessage || "Apple 登录失败。";
}

function explainSessionRestoreError(error) {
  const rawMessage = String(error?.message ?? "");
  if (/jwt.*future|jwt.*expired|invalid.*jwt|auth session missing/i.test(rawMessage)) {
    return "";
  }
  return rawMessage ? "暂时无法确认登录状态，请重新登录。" : "";
}

function isNoFarmAccessError(error) {
  return error?.code === "NO_FARM_ACCESS";
}

export function App() {
  const [readProgress, setReadProgress] = useState("正在确认登录和牧场权限…");
  useEffect(() => subscribeCloudReadProgress(setReadProgress), []);
  const [activePage, setActivePage] = useState("home");
  const [routeContext, setRouteContext] = useState({});
  const [routeRequest, setRouteRequest] = useState({ page: "home", context: {} });
  const [routeLoading, setRouteLoading] = useState(false);
  const [routeTransitionPending, startRouteTransition] = useTransition();
  // Cloud access is mandatory. Never render demo farm data while the real
  // Supabase session is unknown or absent.
  const [workspace, setWorkspace] = useState(null);
  const [recordDialog, setRecordDialog] = useState({ open: false, type: "new" });
  const [authState, setAuthState] = useState({ loading: true, error: "", access: "checking", user: null });
  const [drafts, setDrafts] = useState([]);
  const [writeBusy,setWriteBusy] = useState(false);
  const [writeProgress,setWriteProgress]=useState("");
  const [toast, setToast] = useState(null);

  useEffect(() => {
    let active=true;
    if(workspace?.profile?.accountID) listDrafts(workspace.profile.accountID,workspace.farm.id).then(rows=>{if(active)setDrafts(rows);}).catch(e=>setToast({message:e.message,tone:"danger"}));
    else setDrafts([]);
    return()=>{active=false;};
  },[workspace?.profile?.accountID,workspace?.farm.id]);

  const closeRecordDialog = useCallback(() => {
    setRecordDialog((current) => ({ ...current, open: false }));
  }, []);

  const showToast = useCallback((message, tone = "success") => {
    setToast({ id: createID(), message, tone });
  }, []);

  useEffect(() => {
    if (!toast) return undefined;
    const timer = window.setTimeout(() => setToast(null), 4200);
    return () => window.clearTimeout(timer);
  }, [toast]);

  useEffect(() => {
    let active = true;
    let stopWatching = () => {};
    workspaceDataSource.invalidate();

    async function restoreCloudSession() {
      if (!isSupabaseConfigured) {
        if (active) {
          setWorkspace(null);
          setAuthState({ loading: false, error: "当前网页尚未配置 Supabase 登录环境。", access: "signed-out", user: null });
        }
        return;
      }
      let verifiedUser = null;
      try {
        const cloud = await loadSupabaseModule();
        verifiedUser = await cloud.getVerifiedUser();
        if (!verifiedUser) {
          if (active) {
            setWorkspace(null);
            setAuthState({ loading: false, error: "", access: "signed-out", user: null });
          }
          return;
        }
        const cloudWorkspace = await workspaceDataSource.loadOverview();
        if (active) {
          setWorkspace(cloudWorkspace);
          setAuthState({ loading: false, error: "", access: "member", user: verifiedUser });
        }
      } catch (error) {
        if (active && error?.name !== "AbortError") {
          setWorkspace(null);
          if (isNoFarmAccessError(error)) {
            setAuthState({ loading: false, error: "", access: "invite-only", user: verifiedUser });
          } else {
            setAuthState({ loading: false, error: verifiedUser ? cloudAccessErrorMessage(error) : explainSessionRestoreError(error),
              access: verifiedUser ? "unavailable" : "signed-out", user: verifiedUser });
          }
        }
      }
    }

    void restoreCloudSession();
    if (isSupabaseConfigured) {
      void loadSupabaseModule().then((cloud) => {
        if (!active) return;
        stopWatching = cloud.watchAuth(({ event }) => {
          if (event === "SIGNED_OUT" && active) {
            workspaceDataSource.invalidate();
            setWorkspace(null);
            setAuthState({ loading: false, error: "", access: "signed-out", user: null });
          }
        });
      });
    }

    return () => {
      active = false;
      workspaceDataSource.invalidate();
      stopWatching();
    };
  }, []);

  const searchIndex = useMemo(() => {
    if (!workspace) return [];
    const sheep = (workspace.sheep ?? []).map((item) => ({
      kind: "sheep",
      id: item.id,
      title: `羊只 ${item.earTag}`,
      detail: `${item.breed} · ${item.pen}`,
      haystack: [item.earTag, item.breed, item.pen].join("\n").toLowerCase(),
    }));
    const pens = (workspace.pens ?? []).map((item) => ({
      kind: "pen",
      id: item.id,
      title: item.name,
      detail: item.purpose,
      haystack: [item.name, item.purpose].join("\n").toLowerCase(),
    }));
    const events = (workspace.events ?? []).map((item) => ({
      kind: "event",
      id: item.id,
      title: item.label,
      detail: [item.object, item.detail, item.actor].filter(Boolean).join(" · "),
      haystack: [
        item.label,
        item.object,
        item.detail,
        item.note,
        item.actor,
        ...(item.fields ?? []).flatMap((field) => [field.label, field.value]),
      ].join("\n").toLowerCase(),
    }));
    return sheep.concat(pens, events);
  }, [workspace]);
  const navigate = useCallback((page, context = {}) => {
    setRouteRequest({ page, context });
  }, []);

  useEffect(() => {
    if (!workspace) return undefined;
    const { page, context } = routeRequest;
    const commitRoute = () => {
      startRouteTransition(() => {
        setActivePage(page);
        setRouteContext(context);
      });
      window.scrollTo({ top: 0, behavior: "smooth" });
    };
    const requiredSections = workspaceSectionsForPage(page);
    if (workspaceHasSections(workspace, requiredSections)) {
      setRouteLoading(false);
      commitRoute();
      return undefined;
    }

    let active = true;
    setRouteLoading(true);
    void workspaceDataSource.loadForPage(
      page,
      workspace.farm.id,
      { currentWorkspace: workspace },
    ).then((cloudWorkspace) => {
      if (!active) return;
      setWorkspace(cloudWorkspace);
      commitRoute();
    }).catch((error) => {
      if (!active || error?.name === "AbortError") return;
      const message = error.message || "页面数据装载失败。";
      showToast(message, "danger");
    }).finally(() => {
      if (active) setRouteLoading(false);
    });

    return () => {
      active = false;
    };
  }, [routeRequest, showToast, workspace]);

  function selectSearchResult(result) {
    if (result.kind === "event") {
      navigate("events", { selectedID: result.id });
    } else if (result.kind === "pen") {
      navigate("pens", { selectedID: result.id });
    } else {
      navigate("flock", { selectedID: result.id });
    }
  }

  async function changeFarm(farmID) {
    if (workspace.mode !== "cloud") {
      const farm = workspace.farms.find((item) => item.id === farmID);
      if (farm) setWorkspace((current) => ({ ...current, farm }));
      return;
    }
    setAuthState({ loading: true, error: "" });
    try {
      const cloudWorkspace = await workspaceDataSource.loadOverview(farmID, {
        bypassCache: true,
      });
      setWorkspace(cloudWorkspace);
      showToast(`已切换到 ${cloudWorkspace.farm.name}`);
    } catch (error) {
      if (error?.name === "AbortError") return;
      setAuthState({ loading: false, error: error.message || "牧场切换失败。" });
      showToast(error.message || "牧场切换失败。", "danger");
      return;
    }
    setAuthState({ loading: false, error: "" });
  }

  async function handleSignIn(email, password) {
    workspaceDataSource.invalidate();
    setAuthState((current) => ({ ...current, loading: true, error: "" }));
    try {
      const cloud = await loadSupabaseModule();
      const user = await cloud.signInWithPassword(email, password);
      try {
        const cloudWorkspace = await workspaceDataSource.loadOverview();
        setWorkspace(cloudWorkspace);
        setAuthState({ loading: false, error: "", access: "member", user });
        showToast(`已连接 ${cloudWorkspace.farm.name}`);
      } catch (error) {
        if (error?.name === "AbortError") throw error;
        setWorkspace(null);
        setAuthState({ loading: false, error: isNoFarmAccessError(error) ? "" : cloudAccessErrorMessage(error),
          access: isNoFarmAccessError(error) ? "invite-only" : "unavailable", user });
      }
    } catch (error) {
      if (error?.name === "AbortError") return;
      const message = error.message || "登录失败。";
      setAuthState({ loading: false, error: message, access: "signed-out", user: null });
      throw error;
    }
  }

  async function handleSignUp({ displayName, email, password }) {
    workspaceDataSource.invalidate();
    setAuthState((current) => ({ ...current, loading: true, error: "" }));
    try {
      const cloud = await loadSupabaseModule();
      const result = await cloud.signUpWithPassword({ displayName, email, password });
      if (result.verificationRequired) {
        setAuthState({ loading: false, error: "", access: "signed-out", user: null });
        return result;
      }
      try {
        const cloudWorkspace = await workspaceDataSource.loadOverview();
        setWorkspace(cloudWorkspace);
        setAuthState({ loading: false, error: "", access: "member", user: result.user });
      } catch (error) {
        if (error?.name === "AbortError") throw error;
        setWorkspace(null);
        setAuthState({ loading: false, error: isNoFarmAccessError(error) ? "" : cloudAccessErrorMessage(error),
          access: isNoFarmAccessError(error) ? "invite-only" : "unavailable", user: result.user });
      }
      return result;
    } catch (error) {
      const message = error.message || "注册失败。";
      setAuthState({ loading: false, error: message, access: "signed-out", user: null });
      throw error;
    }
  }

  async function handleRedeemInvite(code) {
    workspaceDataSource.invalidate();
    setAuthState((current) => ({ ...current, loading: true, error: "" }));
    let redeemed = false;
    try {
      const cloud = await loadSupabaseModule();
      const redemption = await cloud.redeemFarmInvite(code);
      redeemed = true;
      const cloudWorkspace = await workspaceDataSource.loadOverview(redemption.farm_id, { bypassCache: true });
      setWorkspace(cloudWorkspace);
      setAuthState((current) => ({ ...current, loading: false, error: "", access: "member" }));
      showToast(`已加入 ${cloudWorkspace.farm.name}`);
    } catch (error) {
      setAuthState((current) => ({ ...current, loading: false, access: redeemed ? "unavailable" : current.access,
        error: error.message || "加入牧场失败。" }));
      throw error;
    }
  }

  async function handleRetryCloudAccess() {
    workspaceDataSource.invalidate();
    setAuthState((current) => ({ ...current, loading: true, error: "" }));
    let user = null;
    try {
      const cloud = await loadSupabaseModule();
      user = await cloud.getVerifiedUser();
      if (!user) {
        setAuthState({ loading: false, error: "登录已过期，请重新登录。", access: "signed-out", user: null });
        return;
      }
      const cloudWorkspace = await workspaceDataSource.loadOverview(undefined, { bypassCache: true });
      setWorkspace(cloudWorkspace);
      setAuthState({ loading: false, error: "", access: "member", user });
    } catch (error) {
      if (error?.name === "AbortError") return;
      setAuthState({ loading: false, error: isNoFarmAccessError(error) ? "" : cloudAccessErrorMessage(error),
        access: isNoFarmAccessError(error) ? "invite-only" : user ? "unavailable" : "signed-out", user });
    }
  }

  async function handleAppleSignIn() {
    setAuthState((current) => ({ ...current, loading: true, error: "" }));
    try {
      const cloud = await loadSupabaseModule();
      await cloud.signInWithApple();
      // Supabase redirects the browser to Apple. This fallback is useful for
      // environments that return from signInWithOAuth without navigating.
      setAuthState((current) => ({ ...current, loading: false, error: "" }));
    } catch (error) {
      const message = explainAppleAuthError(error);
      setAuthState((current) => ({ ...current, loading: false, error: message }));
      throw new Error(message);
    }
  }

  async function handleSignOut() {
    workspaceDataSource.invalidate();
    setAuthState((current) => ({ ...current, loading: true, error: "" }));
    try {
      const cloud = await loadSupabaseModule();
      await cloud.signOut();
      setWorkspace(null);
    } catch (error) {
      setAuthState((current) => ({ ...current, loading: false, error: error.message || "退出失败。" }));
      showToast(error.message || "退出失败。", "danger");
      return;
    }
    setAuthState({ loading: false, error: "", access: "signed-out", user: null });
  }

  async function reloadCloud() {
    if (workspace.mode !== "cloud") return;
    workspaceDataSource.invalidate({ farmID: workspace.farm.id });
    setAuthState({ loading: true, error: "" });
    try {
      const cloudWorkspace = await workspaceDataSource.loadForPage(
        activePage,
        workspace.farm.id,
        {
          currentWorkspace: workspace,
          bypassCache: true,
        },
      );
      setWorkspace(cloudWorkspace);
      setAuthState({ loading: false, error: "" });
      showToast("云端投影已刷新。");
    } catch (error) {
      if (error?.name === "AbortError") return;
      setAuthState({ loading: false, error: error.message || "云端刷新失败。" });
      showToast(error.message || "云端刷新失败。", "danger");
    }
  }

  async function openRecord(type, options={}) {
    setRecordDialog({open:true,type,...options});
  }
  async function refreshDrafts() { setDrafts(await listDrafts(workspace.profile.accountID,workspace.farm.id)); }
  async function persistRecord(record,draftID,submit=false) {
    const draft=await saveDraft(workspace.profile.accountID,workspace.farm,record,draftID);
    await refreshDrafts();
    if(submit) {
      try {await sendSavedDraft(draft);} catch(error) {showToast(error.message,"danger");}
      navigate("entry");
    } else showToast("草稿已保存在此浏览器，重新打开仍可继续。");
    return draft;
  }
  async function sendLabelActions(actions) {
    const results=[];
    const cloud=await loadSupabaseModule();
    for(const action of actions) {
      try {
        const fresh=await cloud.loadCloudWorkspace(workspace.farm.id);
        const record={sheet:"羊只标签",values:{},labelAction:action.action,labelDraft:action.draft};
        const id=action.draft.changeID??action.draft.id;
        const existing=(await listDrafts(workspace.profile.accountID,workspace.farm.id)).find(d=>d.id===id);
        const draft=existing??await saveDraft(workspace.profile.accountID,workspace.farm,record,id);
        const result=await submitDraft(cloud.supabase,workspace.profile.accountID,fresh.farm,draft,()=>buildBusinessCommands(record,fresh));
        const accepted=result.status==="accepted";
        results.push({action,accepted,error:accepted?null:JSON.stringify(result.receipts??result.error??"云端拒绝，请核对回执")});
      } catch(e) { results.push({action,accepted:false,error:e.message}); }
    }
    workspaceDataSource.invalidate({farmID:workspace.farm.id});
    try{setWorkspace(await cloud.loadCloudWorkspace(workspace.farm.id));}catch(e){showToast(`标签提交已处理，读取刷新失败：${e.message}`,"warning");}
    await refreshDrafts();
    return results;
  }
  async function sendSavedDraft(draft) { return sendDraftGroup([draft]); }
  async function sendDraftGroup(group) {
    setWriteBusy(true);let accepted=0;
    try {
      const cloud=await loadSupabaseModule();
      const ordered=[...group].sort((a,b)=>a.createdAt-b.createdAt||(a.record.rowNumber??0)-(b.record.rowNumber??0));
      for(const draft of ordered) {
        setWriteProgress(`正在提交 ${accepted+1} / ${ordered.length} 条`);
        const fresh=await cloud.loadCloudWorkspace(workspace.farm.id);
        const result=await submitDraft(cloud.supabase,workspace.profile.accountID,fresh.farm,draft,()=>buildBusinessCommands({...draft.record,id:draft.id},fresh));
        if(result.status!=="accepted")throw new Error(`${draft.record.sheet}：${result.status==="conflict"?"云端发现冲突":"云端拒绝保存"}，请打开原始回执核对。`);
        accepted++;await refreshDrafts();
      }
      workspaceDataSource.invalidate({farmID:workspace.farm.id});
      try {const fresh=await cloud.loadCloudWorkspace(workspace.farm.id);setWorkspace(fresh);showToast(`云端已接受 ${accepted} 条记录，资料与原始回执已更新。`);}
      catch(e){showToast(`云端已接受 ${accepted} 条记录；读取刷新未完成：${e.message}`,"warning");}
    } catch(e) {throw new Error(`${accepted?`已接受 ${accepted} 条，其余停止提交。`:""}${e.message}`);}
    finally {await refreshDrafts();setWriteBusy(false);setWriteProgress("");}
  }
  async function importRecords(records) {
    const existing=await listDrafts(workspace.profile.accountID,workspace.farm.id);
    const freshRecords=[];
    for(const record of records){const previous=existing.find(d=>d.record.importKey===record.importKey&&d.record.sheet===record.sheet&&d.status!=="discarded");if(previous&&JSON.stringify(previous.record.values)!==JSON.stringify(record.values))throw new Error(`导入键 ${record.importKey} 已有不同内容，请核对原草稿，不能覆盖。`);if(!previous)freshRecords.push(record);}
    if(freshRecords.length){const {preflightImport}=await import("./lib/importPreflight.js");await preflightImport(freshRecords,workspace);}
    let added=0;
    for(const record of records) {
      const previous=existing.find(d=>d.record.importKey===record.importKey&&d.record.sheet===record.sheet&&d.status!=="discarded");
      if(previous) {
        if(JSON.stringify(previous.record.values)!==JSON.stringify(record.values)) throw new Error(`导入键 ${record.importKey} 已有不同内容，请核对原草稿，不能覆盖。`);
        continue;
      }
      const saved=await saveDraft(workspace.profile.accountID,workspace.farm,record);existing.push(saved);added++;
    }
    await refreshDrafts();showToast(`已保存 ${added} 行导入草稿，请按顺序核对并提交。`);
  }
  async function deleteDraft(draft) { await discardDraft(workspace.profile.accountID,draft.id);await refreshDrafts(); }

  if (!workspace) {
    if (!authState.loading) {
      if (authState.access === "unavailable") {
        return <CloudAccessErrorScreen authState={authState} onRetry={handleRetryCloudAccess} onSignOut={handleSignOut} />;
      }
      if (authState.access === "invite-only") {
        return (
          <InviteOnlyAccessScreen
            accountEmail={authState.user?.email}
            authState={authState}
            isConfigured={isSupabaseConfigured}
            onRedeemInvite={handleRedeemInvite}
            onSignOut={handleSignOut}
          />
        );
      }
      return (
        <LoginScreen
          authState={authState}
          isConfigured={isSupabaseConfigured}
          onSignIn={handleSignIn}
          onSignUp={handleSignUp}
          onAppleSignIn={handleAppleSignIn}
        />
      );
    }
    return (
      <div className="app-shell">
        <div className="route-loading session-loading" aria-live="polite">
          <SpinnerGap size={28} className="spin" />
          <strong>eSheep+</strong>
          <span>{readProgress}</span>
        </div>
      </div>
    );
  }

  let content;
  switch (activePage) {
    case "flock":
    case "pens": content = <FlockPage workspace={workspace} initialView={activePage === "pens" ? "pens" : "sheep"} selectedID={routeContext.selectedID} onCreateRecord={openRecord} onLabelSubmit={sendLabelActions} />; break;
    case "alerts": content = <AlertsPage workspace={workspace} selectedID={routeContext.selectedID} onNavigate={navigate} onCreateRecord={openRecord} />; break;
    case "entry": content = <EntryPage drafts={drafts} busy={writeBusy} progress={writeProgress} onSubmitGroup={sendDraftGroup} onResume={draft=>openRecord(draft.record.sheet,{draft})} onSubmitDraft={sendSavedDraft} onDiscardDraft={deleteDraft} onImport={importRecords} workspace={workspace} onCreateRecord={openRecord} onNavigate={navigate} />; break;
    case "care": content = <CarePage workspace={workspace} onCreateRecord={openRecord} />; break;
    case "batches": content = <ProductionBatchesPage workspace={workspace} onCreateRecord={openRecord} />; break;
    case "feeding":
    case "feed-history":
    case "ingredients": content = <FeedingPage workspace={workspace} mode={activePage} onCreateRecord={openRecord} onNavigate={navigate} />; break;
    case "tmr":
    case "tmr-feed":
    case "tmr-produce":
    case "tmr-batches":
    case "tmr-monitor":
    case "tmr-plans":
    case "tmr-formulas": content = <TMRPage workspace={workspace} mode={activePage} onCreateRecord={openRecord} onNavigate={navigate} />; break;
    case "insights":
    case "assistant": content = <InsightsPage workspace={workspace} mode={activePage} onNavigate={navigate} />; break;
    case "search": content = <SearchPage searchIndex={searchIndex} onOpenResult={selectSearchResult} />; break;
    case "events": content = <EventsPage workspace={workspace} selectedID={routeContext.selectedID} exportHint={routeContext.exportHint} />; break;
    case "settings": content = <SettingsPage workspace={workspace} authState={authState} isConfigured={isSupabaseConfigured} onSignIn={handleSignIn} onAppleSignIn={handleAppleSignIn} onSignOut={handleSignOut} onReloadCloud={reloadCloud} />; break;
    default: content = <HomeDashboard workspace={workspace} onNavigate={navigate} onCreateRecord={openRecord} />;
  }

  return (
    <div className="app-shell">
      <AppHeader
        activePage={routeRequest.page}
        onNavigate={navigate}
        workspace={workspace}
        onFarmChange={changeFarm}
        onSignOut={handleSignOut}
      />
      <Suspense fallback={<div className="route-loading"><SpinnerGap size={26} className="spin" />正在打开工作区…</div>}>
        {content}
        {recordDialog.open ? <RecordDialog open requestedType={recordDialog.type} initialDraft={recordDialog.draft} initialValues={recordDialog.values} workspace={workspace} onClose={closeRecordDialog} onSave={persistRecord} /> : null}
      </Suspense>
      {routeLoading || routeTransitionPending ? <div className="route-progress" role="status" aria-label="正在载入页面数据" /> : null}
      {authState.loading || writeBusy ? <div className="loading-scrim" aria-live="polite"><SpinnerGap size={28} className="spin" />{writeProgress || readProgress}</div> : null}
      {toast ? (
        <div className={`toast ${toast.tone}`} role="status">
          {toast.tone === "danger" ? <WarningCircle size={22} weight="fill" /> : <CheckCircle size={22} weight="fill" />}
          <span>{toast.message}</span>
          <button type="button" onClick={() => setToast(null)} aria-label="关闭提示"><X size={17} /></button>
        </div>
      ) : null}
    </div>
  );
}
