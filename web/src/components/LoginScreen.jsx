import { useState } from "react";
import { AppleLogo } from "@phosphor-icons/react/AppleLogo";
import { CloudCheck } from "@phosphor-icons/react/CloudCheck";
import { SignIn } from "@phosphor-icons/react/SignIn";
import { UserPlus } from "@phosphor-icons/react/UserPlus";

export function LoginScreen({ authState, isConfigured, onSignIn, onSignUp, onAppleSignIn }) {
  const [mode, setMode] = useState("sign-in");
  const [displayName, setDisplayName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [passwordConfirmation, setPasswordConfirmation] = useState("");
  const [busy, setBusy] = useState(false);
  const [appleBusy, setAppleBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [messageTone, setMessageTone] = useState("warning");

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setMessage("");
    try {
      if (mode === "register") {
        if (password.length < 8) throw new Error("密码至少需要 8 个字符。");
        if (password !== passwordConfirmation) throw new Error("两次输入的密码不一致。");
        const result = await onSignUp({ displayName, email, password });
        if (result.verificationRequired) {
          setMessageTone("success");
          setMessage("注册申请已提交。请打开确认邮件完成邮箱验证，然后返回登录；免费账号只能通过邀请码加入已有云端牧场。");
        }
      } else {
        await onSignIn(email, password);
      }
      setPassword("");
      setPasswordConfirmation("");
    } catch (error) {
      setMessageTone("warning");
      setMessage(error.message || (mode === "register" ? "注册失败，请检查账号信息。" : "登录失败，请检查账号信息。"));
    } finally {
      setBusy(false);
    }
  }

  async function submitApple() {
    setAppleBusy(true);
    setMessage("");
    try {
      await onAppleSignIn();
    } catch (error) {
      setMessage(error.message || "Apple 登录失败，请稍后重试。");
      setAppleBusy(false);
    }
  }

  const disabled = !isConfigured || busy || appleBusy;

  return (
    <main className="login-screen">
      <section className="login-card" aria-labelledby="login-title">
        <div className="login-brand">
          <img src="/assets/esheepnext-mark.png" alt="" />
          <span><strong id="login-title">eSheep+</strong><small>牧场管理工作台</small></span>
        </div>
        <div className="login-intro">
          <CloudCheck size={22} weight="duotone" />
          <p>{mode === "register" ? "注册免费账号后，需要由已开通云端功能的牧场邀请加入。" : "登录后进入你有权限访问的真实云端牧场。"}</p>
        </div>
        <div className="auth-mode-switch" role="tablist" aria-label="登录或注册">
          <button type="button" role="tab" aria-selected={mode === "sign-in"} className={mode === "sign-in" ? "active" : ""} onClick={() => { setMode("sign-in"); setMessage(""); }}>登录</button>
          <button type="button" role="tab" aria-selected={mode === "register"} className={mode === "register" ? "active" : ""} onClick={() => { setMode("register"); setMessage(""); }}>注册免费账号</button>
        </div>
        <form className="auth-form login-form" onSubmit={submit}>
          {mode === "register" ? <label>显示名称<input type="text" required value={displayName} onChange={(event) => setDisplayName(event.target.value)} autoComplete="name" maxLength="80" disabled={disabled} /></label> : null}
          <label>邮箱<input type="email" required value={email} onChange={(event) => setEmail(event.target.value)} autoComplete="username" disabled={disabled} /></label>
          <label>密码<input type="password" required minLength={mode === "register" ? 8 : undefined} value={password} onChange={(event) => setPassword(event.target.value)} autoComplete={mode === "register" ? "new-password" : "current-password"} disabled={disabled} /></label>
          {mode === "register" ? <label>确认密码<input type="password" required minLength="8" value={passwordConfirmation} onChange={(event) => setPasswordConfirmation(event.target.value)} autoComplete="new-password" disabled={disabled} /></label> : null}
          <button className="primary-button" type="submit" disabled={disabled}>
            {mode === "register" ? <UserPlus size={20} /> : <SignIn size={20} />}
            {busy ? (mode === "register" ? "正在注册…" : "正在登录…") : (mode === "register" ? "注册免费账号" : "登录 eSheep+")}
          </button>
          <div className="auth-divider" aria-hidden="true"><span>或</span></div>
          <button className="apple-auth-button" type="button" onClick={submitApple} disabled={disabled}>
            <AppleLogo size={20} weight="fill" />
            {appleBusy ? "正在跳转 Apple…" : `使用 Apple ${mode === "register" ? "注册 / 登录" : "登录"}`}
          </button>
          {message || authState.error ? <div className={`form-message ${messageTone === "success" ? "success" : ""}`} role="status">{message || authState.error}</div> : null}
        </form>
        <p className="login-boundary">注册不会创建牧场。免费账号只能接受已有云端牧场邀请；新建云端牧场需要单独开通付费权益。</p>
      </section>
    </main>
  );
}
