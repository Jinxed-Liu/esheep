const hosted = "https://rnqrvthbunrzqtprquqx.supabase.co";
const mini = "https://api.esheepplus.com";
const selectionKey = "esheep.production.backend";
let inFlight;
let selected;
let notice;
let priorState;
let readState;
let readCheckedAt = 0;

export const usesProductionSelector = () =>
  typeof location !== "undefined" && location.origin === "https://app.esheepplus.com";

function lastSelection() {
  try { return sessionStorage.getItem(selectionKey) === "mini" ? "mini" : "hosted"; }
  catch { return "hosted"; }
}

export async function readBackendState() {
  if (inFlight) return inFlight;
  inFlight = (async () => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 6000);
    try {
      const response = await fetch("/api/backend-status", {
        cache: "no-store", redirect: "error", credentials: "omit", signal: controller.signal,
      });
      if (!response.ok || !response.headers.get("content-type")?.includes("application/json")) return null;
      const result = await response.json();
      return ["hosted", "mini", "maintenance"].includes(result.state) ? result.state : null;
    } catch { return null; }
    finally { clearTimeout(timer); }
  })().then((state) => {
    readState = state;
    readCheckedAt = Date.now();
    return state;
  }).finally(() => { inFlight = undefined; });
  return inFlight;
}

function displayState(state) {
  const message = state === selected ? "" : state === "maintenance" ? "服务维护中，请先保存草稿。"
    : state === null ? "暂时无法确认云端状态，待传记录会留在本机。"
    : "服务已切换。请保存当前草稿，再重新打开网页并用原账号登录。";
  if (message && !notice) {
    notice = document.createElement("aside");
    notice.setAttribute("role", "status");
    document.body.prepend(notice);
  }
  if (notice) { notice.textContent = message; notice.hidden = !message; }
  if (priorState !== state) {
    priorState = state;
    window.dispatchEvent(new CustomEvent("esheep-backend-state", { detail: { active: state === selected, changed: ["hosted", "mini"].includes(state) && state !== selected } }));
  }
}

export async function initializeBackendSelection() {
  if (!usesProductionSelector()) return;
  const state = await readBackendState();
  selected = ["hosted", "mini"].includes(state) ? state : lastSelection();
  try { sessionStorage.setItem(selectionKey, selected); } catch { /* May be disabled. */ }
  displayState(state);
  const refresh = async () => displayState(await readBackendState());
  document.addEventListener("visibilitychange", () => { if (!document.hidden) void refresh(); });
  window.addEventListener("online", refresh);
}

export function browserBackend(hostedURL, hostedKey, miniKey) {
  if (!usesProductionSelector()) return { url: hostedURL, publishableKey: hostedKey };
  if (selected === "mini") return { url: mini, publishableKey: miniKey };
  return { url: hosted, publishableKey: hostedURL === hosted ? hostedKey : undefined };
}

export async function authorizeCloudRequest(origin, method = "POST") {
  if (!usesProductionSelector()) return;
  const canReuseRead = ["GET", "HEAD"].includes(method) && readState === selected && Date.now() - readCheckedAt < 15_000;
  const state = canReuseRead ? readState : await readBackendState();
  displayState(state);
  if (state !== selected || origin !== (state === "mini" ? mini : hosted) || !["hosted","mini"].includes(state)) {
    throw new Error("云端状态已变化或暂不可用。请保留原草稿，恢复连接后再提交。");
  }
}
