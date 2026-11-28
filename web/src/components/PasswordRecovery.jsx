import { useState } from "react";
import { supabase } from "../lib/supabase.js";
import { supabaseBrowserConfiguration } from "../lib/supabaseConfig.js";
import { authorizeCloudRequest } from "../lib/backendSelection.js";

export async function openRecoveryLink(url) {
  const origin = supabaseBrowserConfiguration.url;
  if (!supabase || url.searchParams.get("backend") !== new URL(origin).host) {
    throw new Error("服务地址已变化，请从登录页重新获取找回密码邮件。");
  }
  await authorizeCloudRequest(origin);
  const fragment = new URLSearchParams(url.hash.slice(1));
  const token = fragment.get("access_token");
  const refresh = fragment.get("refresh_token");
  const code = url.searchParams.get("code");
  let response;
  if (fragment.get("type") === "recovery" && token && refresh) {
    const body = token.split(".")[1]?.replace(/-/g, "+").replace(/_/g, "/");
    if (!body || JSON.parse(atob(body)).iss !== origin + "/auth/v1") {
      throw new Error("找回密码链接与当前服务不匹配，请重新获取邮件。");
    }
    response = await supabase.auth.setSession({ access_token: token, refresh_token: refresh });
  } else if (code) {
    response = await supabase.auth.exchangeCodeForSession(code);
  } else {
    throw new Error("请打开最新一封找回密码邮件中的完整链接。");
  }
  if (response.error || !response.data.session) throw new Error("链接已过期或已使用，请重新获取邮件。");
  window.history.replaceState(null, "", "/account/recovery");
}

export function PasswordRecovery({ error }) {
  const [message, setMessage] = useState(error);
  const [busy, setBusy] = useState(false);
  const [complete, setComplete] = useState(false);
  async function save(event) {
    event.preventDefault();
    const fields = new FormData(event.currentTarget);
    if (fields.get("password") !== fields.get("confirm")) { setMessage("两次输入的密码不一致。"); return; }
    setBusy(true);
    try {
      const { error: failure } = await supabase.auth.updateUser({ password: fields.get("password") });
      if (failure) throw failure;
      setComplete(true);
      setMessage("密码已更新。您可以在牧场手机上使用原账号和新密码登录。");
    } catch (failure) { setMessage(failure.message); }
    finally { setBusy(false); }
  }
  return <main className="login-screen"><section className="login-card">
    <h1>找回密码</h1>
    {!error && !complete && <form className="login-form" onSubmit={save}>
      <label>新密码<input type="password" name="password" autoComplete="new-password" minLength={8} required /></label>
      <label>确认新密码<input type="password" name="confirm" autoComplete="new-password" minLength={8} required /></label>
      <button type="submit" disabled={busy}>保存新密码</button>
    </form>}
    {message && <p role="status">{message}</p>}
    <a href="/">返回牧场登录</a>
  </section></main>;
}
