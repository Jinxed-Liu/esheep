import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { PaperPlaneTilt } from "@phosphor-icons/react/PaperPlaneTilt";
import { buildAssistantSnapshot } from "../lib/assistantSnapshot.js";
import {
  deleteAssistantSession,
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
import { PageTop, ProjectionNotice } from "./pages/FeaturePageShared.jsx";

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
    ? "已恢复这座牧场的 Codex harness 上下文。纯文字由 mimo-v2.5-pro 回答；附加图片时自动切换到 mimo-v2.5。"
    : "这是围绕 Codex harness 建立的只读牧场助手。纯文字使用 mimo-v2.5-pro；附加图片时使用 mimo-v2.5，并且所有牧场数字都通过 App 同口径查询工具核对。";
}

function formattedMessage(text) {
  return String(text ?? "").split(/(\*\*[^*\n]+\*\*|`[^`\n]+`)/g).filter(Boolean).map((part, index) => {
    if (part.startsWith("**") && part.endsWith("**")) return <strong key={`${index}-${part.length}`}>{part.slice(2, -2)}</strong>;
    if (part.startsWith("`") && part.endsWith("`")) return <code key={`${index}-${part.length}`}>{part.slice(1, -1)}</code>;
    return part;
  });
}

export default function FarmAssistant({ workspace, onBack }) {
  const isCloud = workspace.mode === "cloud";
  const credentialAccountID = isCloud ? String(workspace.profile?.accountID ?? "").trim() : "";
  const sessionStorageKey = useMemo(() => storageKey(workspace), [workspace.profile?.accountID, workspace.farm?.id]);
  const initialSession = useMemo(() => readStoredSession(sessionStorageKey), [sessionStorageKey]);
  const [sessionID, setSessionID] = useState(initialSession);
  const [status, setStatus] = useState(null);
  const [statusError, setStatusError] = useState("");
  const [text, setText] = useState("");
  const [attachments, setAttachments] = useState([]);
  const [messages, setMessages] = useState([{ id: "intro", role: "assistant", text: introMessage(workspace, Boolean(initialSession)) }]);
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
  const threadEndRef = useRef(null);

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
    abortRef.current?.abort();
    const stored = readStoredSession(sessionStorageKey);
    setSessionID(stored);
    setMessages([{ id: "intro", role: "assistant", text: introMessage(workspace, Boolean(stored)) }]);
    setAttachments([]);
    setText("");
    setError("");
  }, [sessionStorageKey, workspace.mode]);

  useEffect(() => {
    threadEndRef.current?.scrollIntoView({ behavior: running ? "smooth" : "auto", block: "end" });
  }, [messages, activity, running]);

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
    try {
      const [accessToken, snapshot] = await Promise.all([
        getAssistantAccessToken(),
        Promise.resolve().then(() => buildAssistantSnapshot(workspace)),
      ]);
      await streamAssistantTurn({
        accessToken,
        mimoAPIKey,
        farmID: workspace.farm.id,
        prompt,
        sessionID,
        snapshot,
        attachments: sentAttachments,
        signal: controller.signal,
        onEvent(event) {
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
        },
      });
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

  const clearSession = useCallback(async () => {
    if (running) return;
    setError("");
    try {
      if (sessionID && isCloud) {
        const accessToken = await getAssistantAccessToken();
        await deleteAssistantSession({ accessToken, farmID: workspace.farm.id, sessionID });
      }
      storeSession(sessionStorageKey, null);
      setSessionID(null);
      setMessages([{ id: `intro-${Date.now()}`, role: "assistant", text: introMessage(workspace, false) }]);
      setActivity(status?.configured
        ? (credentialReady ? "新 Codex harness 会话已就绪" : "等待输入个人 MiMo Key")
        : "等待服务端 Supabase 配置");
    } catch (requestError) {
      setError(requestError.message);
    }
  }, [credentialReady, isCloud, running, sessionID, sessionStorageKey, status?.configured, workspace]);

  const canSend = isCloud && status?.configured === true && credentialReady && !running && Boolean(text.trim() || attachments.length);
  const configurationMessage = status?.configured === false
    ? `服务端缺少 ${status.missing?.join("、") || "Supabase 配置"}。`
    : statusError;

  return (
    <main className="page feature-page assistant-page">
      <PageTop title="Codex 牧场助手" description="由 Codex harness 执行；纯文字使用 mimo-v2.5-pro，图片使用 mimo-v2.5。" />
      <div className="assistant-page-actions">
        <button className="text-button back-link" type="button" onClick={onBack}>返回洞察</button>
        <button className="text-button" type="button" onClick={clearSession} disabled={running}>新会话</button>
      </div>
      {isCloud
        ? <ProjectionNotice>助手只读当前 Supabase 牧场快照。每个用户使用自己的 MiMo Key；所选图片只随本次提问进入 Codex harness，AI 结论不会自动写入牧场或替代人工判断。</ProjectionNotice>
        : <ProjectionNotice>当前没有已授权的云端牧场，助手已禁用。</ProjectionNotice>}
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
      <section className="assistant-workspace">
        <header className="assistant-runtime-bar">
          <span className={`assistant-runtime-dot ${status?.configured ? "ready" : "waiting"}`} />
          <div>
            <strong>{activity}</strong>
            <small>{status?.configured
              ? `文字 ${status.model} · 图片 ${status.multimodalModel} · 只读线程`
              : configurationMessage || "正在读取服务状态"}</small>
          </div>
          {sessionID ? <code title="服务端会话已恢复">线程已连接</code> : <code>新线程</code>}
        </header>
        <div className="assistant-thread" aria-live="polite">
          {messages.map((message) => (
            <article className={`${message.role}${message.error ? " message-error" : ""}`} key={message.id}>
              {message.role === "assistant"
                ? <img src="/assets/mimo-assistant.png" alt="" />
                : <span className="user-message-mark">我</span>}
              <div className="assistant-message-body">
                {message.attachments?.length ? <div className="assistant-message-images">{message.attachments.map((attachment) => <img key={attachment.id} src={attachment.dataURL} alt={attachment.name} />)}</div> : null}
                {message.pending ? <span className="assistant-thinking"><i /><i /><i /></span> : <p>{formattedMessage(message.text)}</p>}
              </div>
            </article>
          ))}
          <div ref={threadEndRef} />
        </div>
        <div className="assistant-suggestions">
          {suggestions.map((suggestion) => <button type="button" key={suggestion} onClick={() => send(suggestion)} disabled={!isCloud || status?.configured !== true || !credentialReady || running}>{suggestion}</button>)}
        </div>
        {attachments.length ? (
          <div className="assistant-attachment-tray">
            {attachments.map((attachment) => (
              <figure key={attachment.id}>
                <img src={attachment.dataURL} alt={attachment.name} />
                <figcaption>{attachment.name}</figcaption>
                <button type="button" aria-label={`移除 ${attachment.name}`} onClick={() => removeImage(attachment.id)}>×</button>
              </figure>
            ))}
          </div>
        ) : null}
        {error || configurationMessage ? <p className="assistant-inline-error" role="alert">{error || configurationMessage}</p> : null}
        <form className="assistant-composer" onSubmit={(event) => { event.preventDefault(); send(); }}>
          <input
            ref={fileInputRef}
            className="assistant-file-input"
            type="file"
            accept="image/jpeg,image/png,image/webp"
            multiple
            onChange={(event) => addImages(event.target.files)}
            disabled={!isCloud || !credentialReady || running || attachments.length >= MAX_IMAGES}
          />
          <button className="assistant-attach-button" type="button" onClick={() => fileInputRef.current?.click()} disabled={!isCloud || !credentialReady || running || attachments.length >= MAX_IMAGES}>+ 图片</button>
          <textarea
            value={text}
            onChange={(event) => setText(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) {
                event.preventDefault();
                send();
              }
            }}
            placeholder={isCloud ? (credentialReady ? "询问当前牧场数据，或添加图片…" : "先保存你自己的 MiMo API Key") : "登录云端牧场后可用"}
            disabled={!isCloud || status?.configured !== true || !credentialReady || running}
            rows="1"
          />
          {running
            ? <button className="assistant-stop-button" type="button" onClick={() => abortRef.current?.abort()} aria-label="停止回答">停止</button>
            : <button className="assistant-send-button" type="submit" aria-label="发送" disabled={!canSend}><PaperPlaneTilt size={21} weight="fill" /></button>}
        </form>
      </section>
    </main>
  );
}
