import { lazy, Suspense, useCallback, useEffect, useMemo, useState, useTransition } from "react";
import { CheckCircle } from "@phosphor-icons/react/CheckCircle";
import { SpinnerGap } from "@phosphor-icons/react/SpinnerGap";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";
import { X } from "@phosphor-icons/react/X";
import { AppHeader } from "./components/AppHeader.jsx";
import { HomeDashboard } from "./components/HomeDashboard.jsx";
import { InviteOnlyAccessScreen } from "./components/InviteOnlyAccessScreen.jsx";
import { LoginScreen } from "./components/LoginScreen.jsx";
import { isSupabaseConfigured } from "./lib/supabaseConfig.js";
import {
  WorkspaceDataSource,
  workspaceHasSections,
  workspaceSectionsForPage,
} from "./lib/workspaceDataSource.js";

let supabaseModulePromise;

function loadSupabaseModule() {
  supabaseModulePromise ??= import("./lib/supabase.js");
  return supabaseModulePromise;
}

const workspaceDataSource = new WorkspaceDataSource({
  loadWorkspace: async (farmID, options) => {
    const cloud = await loadSupabaseModule();
    return cloud.loadCloudWorkspace(farmID, options);
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
            setAuthState({ loading: false, error: explainSessionRestoreError(error), access: "signed-out", user: null });
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
        if (!isNoFarmAccessError(error)) throw error;
        setWorkspace(null);
        setAuthState({ loading: false, error: "", access: "invite-only", user });
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
        if (!isNoFarmAccessError(error)) throw error;
        setWorkspace(null);
        setAuthState({ loading: false, error: "", access: "invite-only", user: result.user });
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
    try {
      const cloud = await loadSupabaseModule();
      const redemption = await cloud.redeemFarmInvite(code);
      const cloudWorkspace = await workspaceDataSource.loadOverview(redemption.farm_id, { bypassCache: true });
      setWorkspace(cloudWorkspace);
      setAuthState((current) => ({ ...current, loading: false, error: "", access: "member" }));
      showToast(`已加入 ${cloudWorkspace.farm.name}`);
    } catch (error) {
      setAuthState((current) => ({ ...current, loading: false, error: error.message || "加入牧场失败。" }));
      throw error;
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

  async function openRecord(type) {
    if (workspace.mode === "cloud" && ["feed", "new"].includes(type) &&
        !workspaceHasSections(workspace, ["tmr"])) {
      setAuthState({ loading: true, error: "" });
      try {
        const cloudWorkspace = await workspaceDataSource.loadTMR(
          workspace.farm.id,
          { currentWorkspace: workspace },
        );
        setWorkspace(cloudWorkspace);
      } catch (error) {
        if (error?.name === "AbortError") return;
        const message = error.message || "配方数据装载失败。";
        setAuthState({ loading: false, error: message });
        showToast(message, "danger");
        return;
      }
      setAuthState({ loading: false, error: "" });
    }
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
      if (!draft && record.type === "addSheep") {
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
      if (!draft && record.type === "weight") {
        next.sheep = current.sheep.map((sheep) => sheep.earTag === record.values.sheep
          ? { ...sheep, weight: Number(record.values.kilograms), updatedAt: record.occurredAt }
          : sheep);
      }
      if (!draft && record.type === "transfer") {
        next.sheep = current.sheep.map((sheep) => sheep.earTag === record.values.sheep
          ? { ...sheep, pen: record.values.pen, updatedAt: record.occurredAt }
          : sheep);
      }
      if (!draft && record.type === "removal") {
        next.sheep = current.sheep.filter((sheep) => sheep.earTag !== record.values.sheep);
        next.metrics = { ...current.metrics, activeSheep: Math.max(0, current.metrics.activeSheep - 1) };
      }
      if (!draft && record.type === "feed") {
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
    showToast("已生成浏览器草稿；尚未提交云端。", "warning");
  }

  if (!workspace) {
    if (!authState.loading) {
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
          <span className="visually-hidden">正在准备工作区</span>
        </div>
      </div>
    );
  }

  let content;
  switch (activePage) {
    case "flock":
    case "pens": content = <FlockPage workspace={workspace} initialView={activePage === "pens" ? "pens" : "sheep"} selectedID={routeContext.selectedID} onCreateRecord={openRecord} />; break;
    case "alerts": content = <AlertsPage workspace={workspace} selectedID={routeContext.selectedID} onNavigate={navigate} onCreateRecord={openRecord} />; break;
    case "entry": content = <EntryPage workspace={workspace} onCreateRecord={openRecord} onNavigate={navigate} />; break;
    case "care": content = <CarePage workspace={workspace} onCreateRecord={openRecord} />; break;
    case "batches": content = <ProductionBatchesPage workspace={workspace} />; break;
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
        {recordDialog.open ? <RecordDialog open requestedType={recordDialog.type} workspace={workspace} onClose={closeRecordDialog} onSubmit={submitRecord} /> : null}
      </Suspense>
      {routeLoading || routeTransitionPending ? <div className="route-progress" role="status" aria-label="正在载入页面数据" /> : null}
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
