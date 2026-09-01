import { useState } from "react";
import { ArrowRight } from "@phosphor-icons/react/ArrowRight";
import { SignOut } from "@phosphor-icons/react/SignOut";
import { Ticket } from "@phosphor-icons/react/Ticket";

export function InviteOnlyAccessScreen({ accountEmail, authState, isConfigured, onRedeemInvite, onSignOut }) {
  const [inviteCode, setInviteCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setMessage("");
    try {
      await onRedeemInvite(inviteCode);
    } catch (error) {
      setMessage(error.message || "邀请码兑换失败，请检查后重试。");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="login-screen">
      <section className="login-card invite-only-card" aria-labelledby="invite-only-title">
        <div className="login-brand">
          <img src="/assets/esheepnext-mark.png" alt="" />
          <span><strong id="invite-only-title">等待牧场邀请</strong><small>eSheep+ 免费账号</small></span>
        </div>
        <div className="login-intro invite-only-intro">
          <Ticket size={24} weight="duotone" />
          <p>这个账号已经注册成功，但目前没有可访问的云端牧场。免费账号不能新建云端牧场，只能接受已开通云端功能的牧场邀请。</p>
        </div>
        <div className="signed-account-row"><span>当前账号</span><strong>{accountEmail || "已登录账号"}</strong></div>
        <form className="auth-form invite-code-form" onSubmit={submit}>
          <label>牧场邀请码<input type="text" required value={inviteCode} onChange={(event) => setInviteCode(event.target.value)} autoComplete="one-time-code" spellCheck="false" disabled={!isConfigured || busy || authState.loading} placeholder="粘贴场主提供的邀请码" /></label>
          <button className="primary-button" type="submit" disabled={!isConfigured || busy || authState.loading || !inviteCode.trim()}><ArrowRight size={20} />{busy ? "正在加入…" : "加入云端牧场"}</button>
          {message || authState.error ? <div className="form-message" role="alert">{message || authState.error}</div> : null}
        </form>
        <div className="invite-only-actions">
          <button className="text-button" type="button" onClick={onSignOut} disabled={busy || authState.loading}><SignOut size={17} />退出当前账号</button>
        </div>
        <p className="login-boundary">邀请码只能授予指定牧场的成员权限，不会为该账号创建新牧场。云端套餐和购买入口将在正式定价方案确定后另行开放。</p>
      </section>
    </main>
  );
}
