import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { CheckCircle, SpinnerGap, WarningCircle, X } from "@phosphor-icons/react";
import { AppHeader } from "./components/AppHeader.jsx";
import { HomeDashboard } from "./components/HomeDashboard.jsx";
import { makeDemoWorkspace } from "./data/demoData.js";
import {
  getVerifiedUser,
  isSupabaseConfigured,
  loadCloudWorkspace,
  signInWithApple,
  signInWithPassword,
  signOut,
  watchAuth,
} from "./lib/supabase.js";

const EntryPage = lazy(() => import("./components/FeaturePages.jsx").then((module) => ({ default: module.EntryPage })));
const EventsPage = lazy(() => import("./components/FeaturePages.jsx").then((module) => ({ default: module.EventsPage })));
const FeedingPage = lazy(() => import("./components/FeaturePages.jsx").then((module) => ({ default: module.FeedingPage })));
const FlockPage = lazy(() => import("./components/FeaturePages.jsx").then((module) => ({ default: module.FlockPage })));
const InsightsPage = lazy(() => import("./components/FeaturePages.jsx").then((module) => ({ default: module.InsightsPage })));
const RecordDialog = lazy(() => import("./components/RecordDialog.jsx").then((module) => ({ default: module.RecordDialog })));
const SettingsPage = lazy(() => import("./components/FeaturePages.jsx").then((module) => ({ default: module.SettingsPage })));
const TMRPage = lazy(() => import("./components/FeaturePages.jsx").then((module) => ({ default: module.TMRPage })));

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

    async function restoreCloudSession() {
      if (!isSupabaseConfigured) {
        if (active) {
          setWorkspace(makeDemoWorkspace());
          setAuthState({ loading: false, error: "" });
        }
        return;
      }
      try {
        const user = await getVerifiedUser();
        if (!user) {
          if (active) {
            setWorkspace(makeDemoWorkspace());
            setAuthState({ loading: false, error: "" });
          }
          return;
        }
        const cloudWorkspace = await loadCloudWorkspace();
        if (active) {
          setWorkspace(cloudWorkspace);
          setAuthState({ loading: false, error: "" });
        }
      } catch (error) {
        if (active) {
          setWorkspace(makeDemoWorkspace());
          setAuthState({ loading: false, error: error.message || "云端会话恢复失败。" });
        }
      }
    }

    restoreCloudSession();
    const stopWatching = watchAuth(({ event }) => {
      if (event === "SIGNED_OUT" && active) {
        setWorkspace(makeDemoWorkspace());
        setAuthState({ loading: false, error: "" });
      }
    });

    return () => {
      active = false;
      stopWatching();
    };
  }, []);

  const searchResults = useMemo(() => {
    if (!workspace) return [];
    const needle = query.trim().toLowerCase();
    if (!needle) return [];
    const sheep = workspace.sheep
      .filter((item) => [item.earTag, item.breed, item.pen].some((value) => String(value ?? "").toLowerCase().includes(needle)))
      .map((item) => ({ kind: "sheep", id: item.id, title: `羊只 ${item.earTag}`, detail: `${item.breed} · ${item.pen}` }));
    const pens = workspace.pens
      .filter((item) => [item.name, item.purpose].some((value) => String(value ?? "").toLowerCase().includes(needle)))
      .map((item) => ({ kind: "pen", id: item.id, title: item.name, detail: item.purpose }));
    const events = workspace.events
      .filter((item) => [item.label, item.object, item.actor].some((value) => String(value ?? "").toLowerCase().includes(needle)))
      .map((item) => ({ kind: "event", id: item.id, title: item.label, detail: `${item.object} · ${item.actor}` }));
    return [...sheep, ...pens, ...events].slice(0, 12);
  }, [query, workspace]);

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
    setAuthState({ loading: true, error: "" });
    try {
      const cloudWorkspace = await loadCloudWorkspace(farmID);
      setWorkspace(cloudWorkspace);
      showToast(`已切换到 ${cloudWorkspace.farm.name}`);
    } catch (error) {
      setAuthState({ loading: false, error: error.message || "牧场切换失败。" });
      showToast(error.message || "牧场切换失败。", "danger");
      return;
    }
    setAuthState({ loading: false, error: "" });
  }

  async function handleSignIn(email, password) {
    setAuthState({ loading: true, error: "" });
    try {
      await signInWithPassword(email, password);
      const cloudWorkspace = await loadCloudWorkspace();
      setWorkspace(cloudWorkspace);
      setAuthState({ loading: false, error: "" });
      showToast(`已连接 ${cloudWorkspace.farm.name}`);
    } catch (error) {
      const message = error.message || "登录失败。";
      setAuthState({ loading: false, error: message });
      throw error;
    }
  }

  async function handleAppleSignIn() {
    setAuthState({ loading: true, error: "" });
    try {
      await signInWithApple();
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
    setAuthState({ loading: true, error: "" });
    try {
      await signOut();
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
    setAuthState({ loading: true, error: "" });
    try {
      const cloudWorkspace = await loadCloudWorkspace(workspace.farm.id);
      setWorkspace(cloudWorkspace);
      setAuthState({ loading: false, error: "" });
      showToast("云端投影已刷新。");
    } catch (error) {
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
