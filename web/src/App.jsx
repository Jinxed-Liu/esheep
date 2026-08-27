import { lazy, Suspense, useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { CheckCircle } from "@phosphor-icons/react/CheckCircle";
import { SpinnerGap } from "@phosphor-icons/react/SpinnerGap";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";
import { X } from "@phosphor-icons/react/X";
import { AppHeader } from "./components/AppHeader.jsx";
import { HomeDashboard } from "./components/HomeDashboard.jsx";
import { makeDemoWorkspace } from "./data/demoData.js";
import { isSupabaseConfigured } from "./lib/supabaseConfig.js";

let supabaseModulePromise;

function loadSupabaseModule() {
  supabaseModulePromise ??= import("./lib/supabase.js");
  return supabaseModulePromise;
}

const EntryPage = lazy(() => import("./components/pages/EntryPage.jsx"));
const EventsPage = lazy(() => import("./components/pages/EventsPage.jsx"));
const FeedingPage = lazy(() => import("./components/pages/FeedingPage.jsx"));
const FlockPage = lazy(() => import("./components/pages/FlockPage.jsx"));
const InsightsPage = lazy(() => import("./components/pages/InsightsPage.jsx"));
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

export function App() {
  const [activePage, setActivePage] = useState("home");
  // Do not render the local demo while Supabase session restoration is in
  // flight. The previous default made a signed-in user briefly see a
  // completely different farm and mistake it for their cloud data.
  const [workspace, setWorkspace] = useState(null);
  const [query, setQuery] = useState("");
  const [recordDialog, setRecordDialog] = useState({ open: false, type: "new" });
  const [authState, setAuthState] = useState({ loading: true, error: "" });
  const [toast, setToast] = useState(null);
  const workspaceRequestGeneration = useRef(0);
  const workspaceAbortController = useRef(null);

  const beginWorkspaceRequest = useCallback(() => {
    workspaceAbortController.current?.abort();
    const controller = new AbortController();
    workspaceAbortController.current = controller;
    workspaceRequestGeneration.current += 1;
    return {
      controller,
      generation: workspaceRequestGeneration.current,
    };
  }, []);

  const requestIsCurrent = useCallback((request) => (
    !request.controller.signal.aborted &&
      workspaceRequestGeneration.current === request.generation
  ), []);

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
    const request = beginWorkspaceRequest();

    async function restoreCloudSession() {
      if (!isSupabaseConfigured) {
        if (active) {
          setWorkspace(makeDemoWorkspace());
          setAuthState({ loading: false, error: "" });
        }
        return;
      }
      try {
        const cloud = await loadSupabaseModule();
        const user = await cloud.getVerifiedUser();
        if (!user) {
          if (active && requestIsCurrent(request)) {
            setWorkspace(makeDemoWorkspace());
            setAuthState({ loading: false, error: "" });
          }
          return;
        }
        const cloudWorkspace = await cloud.loadCloudWorkspace(undefined, {
          signal: request.controller.signal,
        });
        if (active && requestIsCurrent(request)) {
          setWorkspace(cloudWorkspace);
          setAuthState({ loading: false, error: "" });
        }
      } catch (error) {
        if (active && requestIsCurrent(request) && error?.name !== "AbortError") {
          setWorkspace(makeDemoWorkspace());
          setAuthState({ loading: false, error: error.message || "云端会话恢复失败。" });
        }
      }
    }

    void restoreCloudSession();
    if (isSupabaseConfigured) {
      void loadSupabaseModule().then((cloud) => {
        if (!active) return;
        stopWatching = cloud.watchAuth(({ event }) => {
          if (event === "SIGNED_OUT" && active) {
            workspaceAbortController.current?.abort();
            workspaceRequestGeneration.current += 1;
            setWorkspace(makeDemoWorkspace());
            setAuthState({ loading: false, error: "" });
          }
        });
      });
    }

    return () => {
      active = false;
      request.controller.abort();
      stopWatching();
    };
  }, [beginWorkspaceRequest, requestIsCurrent]);

  const deferredQuery = useDeferredValue(query);
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
      detail: `${item.object} · ${item.actor}`,
      haystack: [item.label, item.object, item.actor].join("\n").toLowerCase(),
    }));
    return sheep.concat(pens, events);
  }, [workspace]);
  const searchResults = useMemo(() => {
    if (!workspace) return [];
    const needle = deferredQuery.trim().toLowerCase();
    if (!needle) return [];
    return searchIndex.filter((item) => item.haystack.includes(needle)).slice(0, 12);
  }, [deferredQuery, searchIndex, workspace]);

  const navigate = useCallback((page) => {
    setQuery("");
    setActivePage(page);
    window.scrollTo({ top: 0, behavior: "smooth" });
  }, []);

  function selectSearchResult(result) {
    setQuery("");
    navigate(result.kind === "event" ? "events" : "flock");
  }

  async function changeFarm(farmID) {
    if (workspace.mode !== "cloud") {
      const farm = workspace.farms.find((item) => item.id === farmID);
      if (farm) setWorkspace((current) => ({ ...current, farm }));
      return;
    }
    const request = beginWorkspaceRequest();
    setAuthState({ loading: true, error: "" });
    try {
      const cloud = await loadSupabaseModule();
      const cloudWorkspace = await cloud.loadCloudWorkspace(farmID, {
        signal: request.controller.signal,
      });
      if (!requestIsCurrent(request)) return;
      setWorkspace(cloudWorkspace);
      showToast(`已切换到 ${cloudWorkspace.farm.name}`);
    } catch (error) {
      if (!requestIsCurrent(request) || error?.name === "AbortError") return;
      setAuthState({ loading: false, error: error.message || "牧场切换失败。" });
      showToast(error.message || "牧场切换失败。", "danger");
      return;
    }
    setAuthState({ loading: false, error: "" });
  }

  async function handleSignIn(email, password) {
    const request = beginWorkspaceRequest();
    setAuthState({ loading: true, error: "" });
    try {
      const cloud = await loadSupabaseModule();
      await cloud.signInWithPassword(email, password);
      const cloudWorkspace = await cloud.loadCloudWorkspace(undefined, {
        signal: request.controller.signal,
      });
      if (!requestIsCurrent(request)) return;
      setWorkspace(cloudWorkspace);
      setAuthState({ loading: false, error: "" });
      showToast(`已连接 ${cloudWorkspace.farm.name}`);
    } catch (error) {
      if (!requestIsCurrent(request) || error?.name === "AbortError") return;
      const message = error.message || "登录失败。";
      setAuthState({ loading: false, error: message });
      throw error;
    }
  }

  async function handleAppleSignIn() {
    setAuthState({ loading: true, error: "" });
    try {
      const cloud = await loadSupabaseModule();
      await cloud.signInWithApple();
      // Supabase redirects the browser to Apple. This fallback is useful for
      // environments that return from signInWithOAuth without navigating.
      setAuthState({ loading: false, error: "" });
    } catch (error) {
      const message = explainAppleAuthError(error);
      setAuthState({ loading: false, error: message });
      throw new Error(message);
    }
  }

  async function handleSignOut() {
    workspaceAbortController.current?.abort();
    workspaceRequestGeneration.current += 1;
    setAuthState({ loading: true, error: "" });
    try {
      const cloud = await loadSupabaseModule();
      await cloud.signOut();
      setWorkspace(makeDemoWorkspace());
      showToast("已退出云端账号，当前显示演示工作区。", "neutral");
    } catch (error) {
      setAuthState({ loading: false, error: error.message || "退出失败。" });
      showToast(error.message || "退出失败。", "danger");
      return;
    }
    setAuthState({ loading: false, error: "" });
  }

  async function reloadCloud() {
    if (workspace.mode !== "cloud") return;
    const request = beginWorkspaceRequest();
    setAuthState({ loading: true, error: "" });
    try {
      const cloud = await loadSupabaseModule();
      const cloudWorkspace = await cloud.loadCloudWorkspace(workspace.farm.id, {
        signal: request.controller.signal,
      });
      if (!requestIsCurrent(request)) return;
      setWorkspace(cloudWorkspace);
      setAuthState({ loading: false, error: "" });
      showToast("云端投影已刷新。");
    } catch (error) {
      if (!requestIsCurrent(request) || error?.name === "AbortError") return;
      setAuthState({ loading: false, error: error.message || "云端刷新失败。" });
      showToast(error.message || "云端刷新失败。", "danger");
    }
  }

  function openRecord(type) {
    setRecordDialog({ open: true, type });
  }

  function submitRecord(record) {
    const draft = workspace.mode === "cloud";
    const event = {
      id: createID(),
      at: record.occurredAt,
      type: record.eventType,
      label: record.label,
      object: record.object,
      actor: workspace.profile?.displayName ?? "当前用户",
      status: draft ? "draft" : "synced",
    };

    setWorkspace((current) => {
      const next = {
        ...current,
        events: [event, ...current.events],
        lastSyncedAt: draft ? current.lastSyncedAt : new Date().toISOString(),
      };
      if (record.type === "addSheep") {
        const newSheep = {
          id: createID(),
          earTag: record.values.earTag,
          breed: record.values.breed,
          sex: record.values.sex,
          stage: "新建档案",
          pen: record.values.pen || "未分圈",
          weight: null,
          updatedAt: record.occurredAt,
        };
        next.sheep = [newSheep, ...current.sheep];
        next.metrics = { ...current.metrics, activeSheep: current.metrics.activeSheep + 1 };
      }
      if (record.type === "feed") {
        next.feedRecords = [{
          id: createID(),
          at: record.occurredAt,
          pen: record.values.pen,
          meal: record.values.meal,
          recipe: record.values.recipe,
          mode: "限量投喂",
          kilograms: Number(record.values.kilograms),
          dryMatter: null,
        }, ...current.feedRecords];
        next.metrics = { ...current.metrics, feedsToday: current.metrics.feedsToday + 1 };
      }
      return next;
    });

    closeRecordDialog();
    if (draft) {
      showToast("已生成浏览器草稿；尚未提交云端。", "warning");
    } else {
      showToast("记录已写入演示台账。", "success");
    }
  }

  if (!workspace) {
    return (
      <div className="app-shell">
        <div className="route-loading session-loading" aria-live="polite">
          <SpinnerGap size={28} className="spin" />
          正在恢复云端会话…
        </div>
      </div>
    );
  }

  let content;
  switch (activePage) {
    case "flock": content = <FlockPage workspace={workspace} onCreateRecord={openRecord} />; break;
    case "entry": content = <EntryPage workspace={workspace} onCreateRecord={openRecord} />; break;
    case "feeding": content = <FeedingPage workspace={workspace} onCreateRecord={openRecord} />; break;
    case "tmr": content = <TMRPage workspace={workspace} onCreateRecord={openRecord} />; break;
    case "insights": content = <InsightsPage workspace={workspace} />; break;
    case "events": content = <EventsPage workspace={workspace} />; break;
    case "settings": content = <SettingsPage workspace={workspace} authState={authState} isConfigured={isSupabaseConfigured} onSignIn={handleSignIn} onAppleSignIn={handleAppleSignIn} onSignOut={handleSignOut} onReloadCloud={reloadCloud} />; break;
    default: content = <HomeDashboard workspace={workspace} onNavigate={navigate} onCreateRecord={openRecord} />;
  }

  return (
    <div className="app-shell">
      <AppHeader
        activePage={activePage}
        onNavigate={navigate}
        workspace={workspace}
        onFarmChange={changeFarm}
        query={query}
        onQueryChange={setQuery}
        searchResults={searchResults}
        onSearchResult={selectSearchResult}
        onSignOut={handleSignOut}
      />
      <Suspense fallback={<div className="route-loading"><SpinnerGap size={26} className="spin" />正在打开工作区…</div>}>
        {content}
        {recordDialog.open ? <RecordDialog open requestedType={recordDialog.type} workspace={workspace} onClose={closeRecordDialog} onSubmit={submitRecord} /> : null}
      </Suspense>
      {authState.loading ? <div className="loading-scrim" aria-live="polite"><SpinnerGap size={28} className="spin" />正在连接云端…</div> : null}
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
