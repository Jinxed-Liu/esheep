import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ArrowUp } from "@phosphor-icons/react/ArrowUp";
import { ArrowLeft } from "@phosphor-icons/react/ArrowLeft";
import { ChatCircleDots } from "@phosphor-icons/react/ChatCircleDots";
import { Gear } from "@phosphor-icons/react/Gear";
import { MagnifyingGlass } from "@phosphor-icons/react/MagnifyingGlass";
import { Paperclip } from "@phosphor-icons/react/Paperclip";
import { PencilSimpleLine } from "@phosphor-icons/react/PencilSimpleLine";
import { Plus } from "@phosphor-icons/react/Plus";
import { SidebarSimple } from "@phosphor-icons/react/SidebarSimple";
import { Sparkle } from "@phosphor-icons/react/Sparkle";
import { X } from "@phosphor-icons/react/X";
import { assistantHistoryKey, conversationGroup, conversationTitle, historyMessages, readAssistantHistory, writeAssistantHistory } from "../lib/assistantHistory.js";
import "./FarmAssistant.css";
import { buildAssistantSnapshot } from "../lib/assistantSnapshot.js";
import {
  getAssistantStatus,
  streamAssistantTurn,
} from "../lib/assistantClient.js";
import {
  loadMiMoCredential,
  normalizeMiMoAPIKey,
  removeMiMoCredential,
  saveMiMoCredential,
} from "../lib/assistantCredential.js";
import { getAssistantAccessToken } from "../lib/supabase.js";

const MAX_IMAGES = 4;
const MAX_IMAGE_BYTES = 5 * 1_048_576;
const SESSION_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ACCEPTED_IMAGE_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
const suggestions = [
  "当前有效体重样本有多少？请说明截止日和样本边界。",
  "完整产羔的出生死亡率是多少？分母是什么？",
  "近 7 个完整自然日的采食分析里，哪些数据是估算？",
];

function storageKey(workspace) {
  const account = String(workspace.profile?.accountID ?? "unknown");
  const farm = String(workspace.farm?.id ?? "unknown");
  return `esheepnext.assistant.session.v1:${account}:${farm}`;
}

function readStoredSession(key) {
  try {
    const value = localStorage.getItem(key);
    return SESSION_PATTERN.test(value ?? "") ? value : null;
  } catch {
    return null;
  }
}

function storeSession(key, value) {
  try {
    if (value) localStorage.setItem(key, value);
    else localStorage.removeItem(key);
  } catch {
    // The assistant still works for the current page when storage is unavailable.
  }
}

function fileDataURL(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(new Error(`无法读取图片“${file.name}”。`));
    reader.readAsDataURL(file);
  });
}

function introMessage(workspace, resumed = false) {
  if (workspace.mode !== "cloud") {
    return "请先登录并进入你有权访问的云端牧场，然后再使用牧场助手。";
  }
  return resumed
    ? "已恢复这座牧场的 Codex harness 上下文。文字和图片均由 mimo-v2.6-pro 回答。"
    : "这是围绕 Codex harness 建立的只读牧场助手。文字和图片均使用 mimo-v2.6-pro；所有牧场数字都通过 App 同口径查询工具核对。";
}

function formattedMessage(text) {
  return String(text ?? "").split(/(\*\*[^*\n]+\*\*|`[^`\n]+`)/g).filter(Boolean).map((part, index) => {
    if (part.startsWith("**") && part.endsWith("**")) return <strong key={`${index}-${part.length}`}>{part.slice(2, -2)}</strong>;
    if (part.startsWith("`") && part.endsWith("`")) return <code key={`${index}-${part.length}`}>{part.slice(1, -1)}</code>;
    return part;
  });
}

export default function FarmAssistant(props) {
  // Remount across account/farm boundaries so a late stream cannot enter another farm's history.
  return <FarmAssistantWorkspace key={`${storageKey(props.workspace)}:${props.workspace.mode}`} {...props} />;
}

function FarmAssistantWorkspace({ workspace, onBack }) {
  const isCloud = workspace.mode === "cloud";
  const credentialAccountID = isCloud ? String(workspace.profile?.accountID ?? "").trim() : "";
  const sessionStorageKey = useMemo(() => storageKey(workspace), [workspace.profile?.accountID, workspace.farm?.id]);
  const historyKey = assistantHistoryKey(workspace.profile?.accountID, workspace.farm?.id);
  const [initialHistory] = useState(() => readAssistantHistory(historyKey));
  const [conversations, setConversations] = useState(initialHistory.conversations);
  const [activeID, setActiveID] = useState(() => initialHistory.activeID ?? crypto.randomUUID());
  const initialConversation = initialHistory.conversations.find((item) => item.id === initialHistory.activeID);
  const initialSession = initialConversation?.sessionID ?? readStoredSession(sessionStorageKey);
  const [historyError, setHistoryError] = useState(initialHistory.error);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [historyCollapsed, setHistoryCollapsed] = useState(() => {
    try { return localStorage.getItem(`${historyKey}:collapsed`) === "true"; } catch { return false; }
  });
  const [isNarrow, setIsNarrow] = useState(() => window.matchMedia("(max-width: 760px)").matches);
  const [historySearch, setHistorySearch] = useState("");
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [renaming, setRenaming] = useState(false);
  const [renameText, setRenameText] = useState("");
  const settingsRef = useRef(null);
  const historySearchRef = useRef(null);
  const historyToggleRef = useRef(null);
  const threadRef = useRef(null);
  const followScrollRef = useRef(true);
  const historyWasOpenRef = useRef(false);
  const [sessionID, setSessionID] = useState(initialSession);
  const [status, setStatus] = useState(null);
  const [statusError, setStatusError] = useState("");
  const [text, setText] = useState(initialConversation?.draft ?? "");
  const [attachments, setAttachments] = useState([]);
  const [messages, setMessages] = useState(initialConversation?.messages ?? []);
  const [activity, setActivity] = useState("正在检查 Codex harness");
  const [error, setError] = useState("");
  const [running, setRunning] = useState(false);
  const [credential, setCredential] = useState({ phase: isCloud ? "loading" : "unavailable", keyType: null, persistence: null });
  const [credentialInput, setCredentialInput] = useState("");
  const [credentialError, setCredentialError] = useState("");
  const [editingCredential, setEditingCredential] = useState(false);
  const [savingCredential, setSavingCredential] = useState(false);
  const credentialRef = useRef(null);
  const abortRef = useRef(null);
  const fileInputRef = useRef(null);

  useEffect(() => {
    const controller = new AbortController();
    getAssistantStatus({ signal: controller.signal })
      .then((nextStatus) => {
        setStatus(nextStatus);
        setStatusError("");
        const hasCurrentCredential = credentialRef.current?.accountID === credentialAccountID;
        setActivity(nextStatus.configured
          ? (isCloud ? (hasCurrentCredential ? "个人 MiMo Key 已就绪" : "等待输入个人 MiMo Key") : "Codex harness 已就绪")
          : "等待服务端 Supabase 配置");
      })
      .catch((requestError) => {
        if (requestError.name === "AbortError") return;
        setStatusError(requestError.message);
        setActivity("Codex harness 连接失败");
      });
    return () => controller.abort();
  }, [credentialAccountID, isCloud]);

  useEffect(() => {
    let active = true;
    credentialRef.current = null;
    setCredentialInput("");
    setCredentialError("");
    setEditingCredential(false);
    if (!isCloud || !credentialAccountID) {
      setCredential({ phase: "unavailable", keyType: null, persistence: null });
      return () => { active = false; };
    }
    setCredential({ phase: "loading", keyType: null, persistence: null });
    loadMiMoCredential(credentialAccountID)
      .then((stored) => {
        if (!active) return;
        credentialRef.current = stored ? { accountID: credentialAccountID, apiKey: stored.apiKey } : null;
        setCredential(stored
          ? { phase: "ready", keyType: stored.keyType, persistence: stored.persistence }
          : { phase: "missing", keyType: null, persistence: null });
        setActivity(stored ? "个人 MiMo Key 已就绪" : "等待输入个人 MiMo Key");
      })
      .catch(() => {
        if (!active) return;
        setCredential({ phase: "missing", keyType: null, persistence: null });
        setActivity("等待输入个人 MiMo Key");
      });
    return () => { active = false; };
  }, [credentialAccountID, isCloud]);

  useEffect(() => {
    if (initialHistory.error) return; // Preserve unreadable records for recovery.
    if (!messages.length && !sessionID && !text.trim()) return;
    setConversations((current) => {
      const existing = current.find((item) => item.id === activeID);
      const next = {
        id: activeID, title: !existing || (existing.title === "新对话" && !existing.messages.some((message) => message.role === "user")) ? conversationTitle(messages) : existing.title, sessionID, messages,
        draft: text, updatedAt: existing?.messages === messages ? existing.updatedAt : Date.now(),
      };
      return [next, ...current.filter((item) => item.id !== activeID)];
    });
  }, [activeID, messages, sessionID, text, initialHistory.error]);

  useEffect(() => {
    if (initialHistory.error) return;
    // Persist immediately on committed updates, including before navigation/unmount.
    setHistoryError(writeAssistantHistory(historyKey, conversations, activeID));
  }, [activeID, conversations, historyKey, initialHistory.error]);

  useEffect(() => {
    if (followScrollRef.current && threadRef.current) threadRef.current.scrollTop = threadRef.current.scrollHeight;
  }, [messages, activity, running, activeID]);

  useEffect(() => {
    const dialog = settingsRef.current;
    if (settingsOpen && !dialog.open) dialog.showModal();
    else if (!settingsOpen && dialog.open) dialog.close();
  }, [settingsOpen]);

  useEffect(() => {
    if (historyOpen) historySearchRef.current?.focus();
    else if (historyWasOpenRef.current) historyToggleRef.current?.focus();
    historyWasOpenRef.current = historyOpen;
  }, [historyOpen]);

  useEffect(() => {
    const media = window.matchMedia("(max-width: 760px)");
    const change = () => { setIsNarrow(media.matches); setHistoryOpen(false); };
    media.addEventListener("change", change);
    return () => media.removeEventListener("change", change);
  }, []);

  useEffect(() => {
    try { localStorage.setItem(`${historyKey}:collapsed`, String(historyCollapsed)); } catch { /* Current page remains usable. */ }
  }, [historyKey, historyCollapsed]);

  useEffect(() => () => abortRef.current?.abort(), []);

  const credentialReady = credential.phase === "ready" && credentialRef.current?.accountID === credentialAccountID;

  const saveCredential = useCallback(async (event) => {
    event.preventDefault();
    if (!credentialAccountID || savingCredential || running) return;
    setCredentialError("");
    setSavingCredential(true);
    try {
      const apiKey = normalizeMiMoAPIKey(credentialInput);
      const stored = await saveMiMoCredential(credentialAccountID, apiKey);
      credentialRef.current = { accountID: credentialAccountID, apiKey: stored.apiKey };
      setCredential({ phase: "ready", keyType: stored.keyType, persistence: stored.persistence });
      setCredentialInput("");
      setEditingCredential(false);
      setSettingsOpen(false);
      setActivity("个人 MiMo Key 已就绪");
    } catch (saveError) {
      setCredentialError(saveError.message);
    } finally {
      setSavingCredential(false);
    }
  }, [credentialAccountID, credentialInput, running, savingCredential]);

  const removeCredential = useCallback(async () => {
    if (!credentialAccountID || savingCredential || running) return;
    setCredentialError("");
    setSavingCredential(true);
    try {
      await removeMiMoCredential(credentialAccountID);
      credentialRef.current = null;
      setCredential({ phase: "missing", keyType: null, persistence: null });
      setCredentialInput("");
      setEditingCredential(false);
      setActivity("等待输入个人 MiMo Key");
    } catch (removeError) {
      setCredentialError(removeError.message);
    } finally {
      setSavingCredential(false);
    }
  }, [credentialAccountID, running, savingCredential]);

  const addImages = useCallback(async (fileList) => {
    const available = Math.max(0, MAX_IMAGES - attachments.length);
    const files = [...(fileList ?? [])].slice(0, available);
    if (!files.length) return;
    setError("");
    try {
      for (const file of files) {
        if (!ACCEPTED_IMAGE_TYPES.has(file.type)) throw new Error("仅支持 JPEG、PNG 和 WebP 图片。");
        if (!file.size || file.size > MAX_IMAGE_BYTES) throw new Error(`图片“${file.name}”不能超过 5 MB。`);
      }
      const prepared = await Promise.all(files.map(async (file) => ({
        id: crypto.randomUUID(),
        name: file.name,
        mimeType: file.type,
        size: file.size,
        dataURL: await fileDataURL(file),
      })));
      setAttachments((current) => [...current, ...prepared].slice(0, MAX_IMAGES));
    } catch (imageError) {
      setError(imageError.message);
    } finally {
      if (fileInputRef.current) fileInputRef.current.value = "";
    }
  }, [attachments.length]);

  const removeImage = useCallback((id) => {
    setAttachments((current) => current.filter((attachment) => attachment.id !== id));
  }, []);

  const send = useCallback(async (requestedPrompt = null) => {
    const prompt = String(requestedPrompt ?? text).trim();
    const selectedAttachments = attachments;
    const mimoAPIKey = credentialRef.current?.accountID === credentialAccountID ? credentialRef.current.apiKey : null;
    if ((!prompt && !selectedAttachments.length) || running || !isCloud || status?.configured !== true || !credentialReady || !mimoAPIKey) return;
    followScrollRef.current = true;
    const stamp = Date.now();
    const pendingID = `${stamp}-pending`;
    const userID = `${stamp}-user`;
    const sentAttachments = selectedAttachments.map(({ name, mimeType, dataURL }) => ({ name, mimeType, dataURL }));
    setMessages((current) => [...current,
      { id: userID, role: "user", text: prompt || "请分析这些图片。", attachments: selectedAttachments },
      { id: pendingID, role: "assistant", text: "", pending: true },
    ]);
    setText("");
    setAttachments([]);
    setError("");
    setRunning(true);
    setActivity(selectedAttachments.length ? "正在上传所选图片" : "正在连接 Codex harness");
    const controller = new AbortController();
    abortRef.current = controller;
    const responseItemIDs = new Map();
    let requestSessionID = sessionID;
    let recoveredExpiredSession = false;
    try {
      const [accessToken, snapshot] = await Promise.all([
        getAssistantAccessToken(),
        Promise.resolve().then(() => buildAssistantSnapshot(workspace)),
      ]);
      const handleEvent = (event) => {
        if (event.type === "session") {
          setSessionID(event.sessionID);
          storeSession(sessionStorageKey, event.sessionID);
          setActivity(event.multimodal ? `${event.model} 正在进行图片理解` : `${event.model} 正在回答`);
        } else if (event.type === "status") {
          setActivity(event.message);
        } else if (event.type === "assistant") {
          const existingID = responseItemIDs.get(event.itemID);
          if (!responseItemIDs.size) {
            responseItemIDs.set(event.itemID, event.itemID);
            setMessages((current) => current.map((message) => message.id === pendingID
              ? { id: event.itemID, role: "assistant", text: event.text }
              : message));
          } else if (existingID) {
            setMessages((current) => current.map((message) => message.id === existingID
              ? { ...message, text: event.text, pending: false }
              : message));
          } else {
            responseItemIDs.set(event.itemID, event.itemID);
            setMessages((current) => [...current, { id: event.itemID, role: "assistant", text: event.text }]);
          }
        } else if (event.type === "done") {
          setActivity(`${event.model} · 回答完成`);
        }
      };
      while (true) {
        try {
          await streamAssistantTurn({
            accessToken,
            mimoAPIKey,
            farmID: workspace.farm.id,
            prompt,
            sessionID: requestSessionID,
            snapshot,
            attachments: sentAttachments,
            signal: controller.signal,
            onEvent: handleEvent,
          });
          break;
        } catch (requestError) {
          if (requestError.code !== "SESSION_EXPIRED" || !requestSessionID || recoveredExpiredSession || controller.signal.aborted) {
            throw requestError;
          }
          recoveredExpiredSession = true;
          requestSessionID = null;
          responseItemIDs.clear();
          setSessionID(null);
          storeSession(sessionStorageKey, null);
          setError("");
          setActivity("旧会话已过期，正在新建会话并重试");
        }
      }
      setMessages((current) => current.map((message) => message.id === pendingID
        ? { ...message, pending: false, text: message.text || "模型没有返回可显示的回答。" }
        : message));
    } catch (requestError) {
      const stopped = requestError.name === "AbortError" || requestError.code === "TURN_ABORTED";
      setMessages((current) => current.map((message) => message.id === pendingID
        ? { ...message, pending: false, error: true, text: stopped ? "本次回答已停止。" : requestError.message }
        : message));
      if (!stopped) setError(requestError.message);
      setActivity(stopped ? "已停止" : "回答失败");
    } finally {
      if (abortRef.current === controller) abortRef.current = null;
      setRunning(false);
    }
  }, [attachments, credentialAccountID, credentialReady, isCloud, running, sessionID, sessionStorageKey, status?.configured, text, workspace]);

  const closeHistory = () => {
    setHistoryOpen(false);
  };

  const selectConversation = (conversation) => {
    if (running) return;
    setActiveID(conversation.id);
    setSessionID(conversation.sessionID);
    storeSession(sessionStorageKey, conversation.sessionID);
    setMessages(conversation.messages);
    setText(conversation.draft ?? "");
    setAttachments([]);
    setError("");
    setRenaming(false);
    followScrollRef.current = true;
    setActivity("已打开聊天记录");
    if (historyOpen) closeHistory();
  };

  const newConversation = () => {
    if (running) return;
    setActiveID(crypto.randomUUID());
    storeSession(sessionStorageKey, null);
    setSessionID(null);
    setMessages([]);
    setText("");
    setAttachments([]);
    setError("");
    setRenaming(false);
    followScrollRef.current = true;
    setActivity(credentialReady ? "新对话已就绪" : "等待输入个人 MiMo Key");
    if (historyOpen) closeHistory();
  };

  const activeConversation = conversations.find((item) => item.id === activeID);
  const filteredConversations = conversations.filter((item) => {
    const search = historySearch.trim().toLocaleLowerCase();
    return !search || `${item.title} ${item.messages.map((message) => message.text).join(" ")}`.toLocaleLowerCase().includes(search);
  }).sort((a, b) => b.updatedAt - a.updatedAt);
  const hasMessages = messages.length > 0;
  const openSettings = () => setSettingsOpen(true);

  const canSend = isCloud && status?.configured === true && credentialReady && !running && Boolean(text.trim() || attachments.length);
  const configurationMessage = status?.configured === false
    ? `服务端缺少 ${status.missing?.join("、") || "Supabase 配置"}。`
    : statusError;

  return (
    <main className={`page feature-page assistant-page${historyOpen ? " history-open" : ""}${historyCollapsed ? " history-collapsed" : ""}`}>
      <section className="assistant-layout" aria-label="牧场助手聊天工作区">
        <button className="assistant-history-backdrop" type="button" aria-label="关闭聊天记录" onClick={closeHistory} tabIndex={historyOpen ? 0 : -1} />
        <aside className="assistant-history" id="assistant-history" role={isNarrow && historyOpen ? "dialog" : "complementary"} aria-modal={isNarrow && historyOpen ? true : undefined} aria-label="聊天记录" onKeyDown={(event) => {
          if (event.key === "Escape") closeHistory();
          if (event.key === "Tab" && historyOpen) {
            const controls = [...event.currentTarget.querySelectorAll('button:not(:disabled), input')];
            const first = controls[0], last = controls.at(-1);
            if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
            else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
          }
        }}>
          <div className="assistant-history-back"><button type="button" onClick={onBack}><ArrowLeft size={18} />返回洞察</button><button className="assistant-history-close" type="button" aria-label="关闭聊天记录" onClick={closeHistory}><X size={18} /></button></div>
          <h2>聊天记录</h2>
          <button className="assistant-new-chat" type="button" onClick={newConversation} disabled={running}><Plus size={20} />新对话</button>
          <label className="assistant-history-search"><MagnifyingGlass size={18} /><input ref={historySearchRef} value={historySearch} onChange={(event) => setHistorySearch(event.target.value)} placeholder="搜索聊天记录…" aria-label="搜索聊天记录" /></label>
          <nav className="assistant-conversation-list" aria-label="历史对话">
            {["今天", "最近"].map((group) => {
              const items = filteredConversations.filter((item) => conversationGroup(item.updatedAt) === group);
              return items.length ? <section key={group}><h3>{group}</h3>{items.map((item) => <button type="button" className={item.id === activeID ? "selected" : ""} aria-current={item.id === activeID ? "true" : undefined} key={item.id} onClick={() => selectConversation(item)} disabled={running} title={item.title}><ChatCircleDots size={19} /><span>{item.title}</span><time>{new Date(item.updatedAt).toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" })}</time></button>)}</section> : null;
            })}
            {!filteredConversations.length ? <p className="assistant-history-empty">{historySearch ? "没有找到相关对话" : "开始一次对话，它会出现在这里。"}</p> : null}
          </nav>
          <div className="assistant-history-footer"><button type="button" onClick={openSettings}><Gear size={21} />设置与密钥<span>›</span></button><small>记录保存在此浏览器</small></div>
        </aside>
        <section className="assistant-workspace" inert={isNarrow && historyOpen ? true : undefined}>
          <header className="assistant-toolbar">
            <button ref={historyToggleRef} className="assistant-tool-button" type="button" aria-label="切换聊天记录" aria-controls="assistant-history" aria-expanded={isNarrow ? historyOpen : !historyCollapsed} onClick={() => { if (isNarrow) setHistoryOpen(!historyOpen); else setHistoryCollapsed(!historyCollapsed); }}><SidebarSimple size={22} /></button>
            <div className="assistant-toolbar-title"><Sparkle size={25} weight="fill" /><h1>牧场助手</h1><span>{status?.model || "mimo-v2.6-pro"}</span></div>
            <span className={`assistant-connection${status?.configured && credentialReady ? " ready" : ""}`} title={configurationMessage || activity}><i />{running ? "回答中" : statusError ? "连接失败" : credentialReady && status?.configured ? "就绪" : "待配置"}</span>
            <button className="assistant-tool-button assistant-mobile-new" type="button" aria-label="新对话" onClick={newConversation} disabled={running}><Plus size={22} /></button>
            <button className="assistant-tool-button assistant-settings-button" type="button" onClick={openSettings} aria-label="助手设置"><Gear size={22} /><span>设置</span></button>
          </header>
          {activeConversation && hasMessages ? <div className="assistant-conversation-title">{renaming ? <form onSubmit={(event) => { event.preventDefault(); if (renameText.trim()) setConversations((current) => current.map((item) => item.id === activeID ? { ...item, title: renameText.trim().slice(0, 80) } : item)); setRenaming(false); }}><input autoFocus aria-label="对话名称" value={renameText} onChange={(event) => setRenameText(event.target.value)} maxLength={80} /><button type="submit">保存</button><button type="button" onClick={() => setRenaming(false)}>取消</button></form> : <><span>{activeConversation.title}</span><button type="button" aria-label="重命名对话" onClick={() => { setRenameText(activeConversation.title); setRenaming(true); }} disabled={running}><PencilSimpleLine size={15} /></button></>}</div> : null}
          <div ref={threadRef} className={`assistant-thread${hasMessages ? "" : " is-empty"}`} role="log" aria-label="聊天消息" aria-live="polite" aria-relevant="additions text" onScroll={(event) => { const node = event.currentTarget; followScrollRef.current = node.scrollHeight - node.scrollTop - node.clientHeight < 80; }}>
            {hasMessages ? <div className="assistant-message-list">{messages.map((message) => (
              <article className={`${message.role}${message.error ? " message-error" : ""}`} key={message.id}>
                {message.role === "assistant" ? <span className="assistant-message-avatar"><Sparkle size={21} weight="fill" /></span> : null}
                <div className="assistant-message-body">
                  {message.attachments?.length ? <div className="assistant-message-images">{message.attachments.map((attachment, index) => attachment.dataURL ? <img key={attachment.id ?? index} src={attachment.dataURL} alt={attachment.name} /> : <span className="assistant-image-reference" key={index}><Paperclip size={16} />{attachment.name} · 图片未保留</span>)}</div> : null}
                  {message.pending ? <span className="assistant-thinking" aria-label="正在回答"><i /><i /><i /></span> : <p>{formattedMessage(message.text)}</p>}
                </div>
              </article>
            ))}</div> : <div className="assistant-welcome"><span className="assistant-welcome-mark"><Sparkle size={35} weight="fill" /></span><h2>今天想了解牧场的什么？</h2><p>查询记录、核对数据，一起看懂牧场的变化。</p>{sessionID ? <small>已连接此前的会话，早期消息未保存在此浏览器。</small> : null}<div className="assistant-suggestions">{suggestions.map((suggestion, index) => <button type="button" key={suggestion} onClick={() => { setText(suggestion); if (!credentialReady) openSettings(); }} disabled={!isCloud || running}><span>{["体重与增重", "产羔与繁殖", "采食与营养"][index]}</span><small>{suggestion}</small><ArrowUp size={16} /></button>)}</div></div>}
          </div>
          <div className="assistant-composer-dock">
            {!isCloud ? <p className="assistant-inline-error">{introMessage(workspace)}</p> : null}
            {isCloud && !credentialReady && credential.phase !== "loading" ? <button className="assistant-key-prompt" type="button" onClick={openSettings}><Gear size={17} />设置我的 MiMo Key，开始对话<span>→</span></button> : null}
            {error || configurationMessage || historyError ? <p className="assistant-inline-error" role="alert">{error || configurationMessage || historyError}</p> : null}
            <form className="assistant-composer" onSubmit={(event) => { event.preventDefault(); send(); }}>
              {attachments.length ? <div className="assistant-attachment-tray">{attachments.map((attachment) => <figure key={attachment.id}><img src={attachment.dataURL} alt={attachment.name} /><figcaption>{attachment.name}</figcaption><button type="button" aria-label={`移除 ${attachment.name}`} onClick={() => removeImage(attachment.id)}><X size={14} /></button></figure>)}</div> : null}
              <input ref={fileInputRef} className="assistant-file-input" type="file" accept="image/jpeg,image/png,image/webp" multiple onChange={(event) => addImages(event.target.files)} disabled={!isCloud || !credentialReady || running || attachments.length >= MAX_IMAGES} />
              <textarea key={activeID} aria-label="提问内容" value={text} onChange={(event) => { setText(event.target.value); event.target.style.height = "auto"; event.target.style.height = `${Math.min(event.target.scrollHeight, 160)}px`; }} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); send(); } }} placeholder="询问牧场数据，或添加图片…" disabled={!isCloud || running} rows="1" />
              <div className="assistant-composer-actions"><button className="assistant-attach-button" type="button" onClick={() => fileInputRef.current?.click()} disabled={!isCloud || !credentialReady || running || attachments.length >= MAX_IMAGES}><Paperclip size={20} />图片</button><span>{running ? activity : "Enter 发送 · Shift + Enter 换行"}</span>{running ? <button className="assistant-stop-button" type="button" onClick={() => abortRef.current?.abort()} aria-label="停止回答"><span /></button> : <button className="assistant-send-button" type="submit" aria-label="发送" disabled={!canSend}><ArrowUp size={23} weight="bold" /></button>}</div>
            </form>
            <p className="assistant-readonly-note">只读牧场数据 · AI 建议请结合实际判断</p>
          </div>
        </section>
      </section>
      <dialog className="assistant-settings" ref={settingsRef} onCancel={() => setSettingsOpen(false)} onClose={() => setSettingsOpen(false)} onClick={(event) => { if (event.target === event.currentTarget) setSettingsOpen(false); }}>
        <div className="assistant-settings-content"><header><div><h2>助手设置</h2><p>文字和图片均使用 mimo-v2.6-pro</p></div><button type="button" className="assistant-tool-button" aria-label="关闭设置" onClick={() => setSettingsOpen(false)}><X size={22} /></button></header>
      {isCloud ? (
        <section className={`assistant-credential-card${credentialReady ? " saved" : ""}`} aria-label="个人 MiMo API Key">
          <div className="assistant-credential-copy">
            <strong>我的 MiMo API Key</strong>
            <small>每台浏览器首次填写一次，之后自动使用；Key 不写入牧场数据或 Codex 会话。</small>
          </div>
          {credential.phase === "loading" ? <span className="assistant-credential-loading">正在读取本机凭据…</span> : null}
          {credentialReady && !editingCredential ? (
            <div className="assistant-credential-saved">
              <span><b>{credential.keyType}</b><small>{credential.persistence === "device" ? "已在此浏览器加密保存" : "浏览器私密存储不可用，仅当前页面有效"}</small></span>
              <button type="button" onClick={() => { setCredentialInput(""); setCredentialError(""); setEditingCredential(true); }} disabled={running || savingCredential}>更换密钥</button>
              <button className="danger" type="button" onClick={removeCredential} disabled={running || savingCredential}>移除密钥</button>
            </div>
          ) : null}
          {(credential.phase === "missing" || editingCredential) ? (
            <form className="assistant-credential-form" onSubmit={saveCredential}>
              <label htmlFor="assistant-mimo-key">MiMo API Key</label>
              <input
                id="assistant-mimo-key"
                name="mimo-api-key"
                type="password"
                autoComplete="off"
                spellCheck="false"
                value={credentialInput}
                onChange={(event) => setCredentialInput(event.target.value)}
                placeholder="sk-… 或 tp-…"
                minLength="12"
                maxLength="512"
                disabled={running || savingCredential}
                required
              />
              <button type="submit" disabled={running || savingCredential || !credentialInput.trim()}>{savingCredential ? "正在保存" : "保存并使用"}</button>
              {credentialReady ? <button className="secondary" type="button" onClick={() => { setCredentialInput(""); setCredentialError(""); setEditingCredential(false); }} disabled={savingCredential}>取消</button> : null}
            </form>
          ) : null}
          {credentialError ? <p className="assistant-credential-error" role="alert">{credentialError}</p> : null}
        </section>
      ) : null}

          <div className="assistant-settings-about"><h3>关于对话与数据</h3><p>助手只读当前已授权的云端牧场快照，数字使用与 App 一致的查询口径。AI 结论不会自动写入牧场。</p><p>聊天文字保存在当前浏览器，按账号与牧场区分，不跨设备同步。图片仅随本次提问发送，重新打开记录时只显示文件名。</p><p>服务端会话可能休眠或过期，届时会保留聊天文字，并自动新建上下文重试本次提问。</p></div>
        </div>
      </dialog>
    </main>
  );
}
