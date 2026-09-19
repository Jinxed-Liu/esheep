import { ArrowClockwise } from "@phosphor-icons/react/ArrowClockwise";
import { SignOut } from "@phosphor-icons/react/SignOut";

export function CloudAccessErrorScreen({ authState, onRetry, onSignOut }) {
  return (
    <main className="login-screen">
      <section className="login-card invite-only-card" aria-labelledby="cloud-access-error-title">
        <div className="login-brand">
          <img src="/assets/esheepplus-icon.png" alt="" />
          <span><strong id="cloud-access-error-title">暂时无法打开牧场</strong><small>eSheep+ 云端牧场</small></span>
        </div>
        <div className="login-intro"><p>你已登录。牧场资料未能完成读取，请重试。</p></div>
        <div className="signed-account-row"><span>当前账号</span><strong>{authState.user?.email || "已登录账号"}</strong></div>
        <div className="form-message" role="alert">{authState.error}</div>
        <div className="auth-form">
          <button className="primary-button" type="button" onClick={onRetry} disabled={authState.loading}>
            <ArrowClockwise size={20} />重新读取牧场
          </button>
        </div>
        <div className="invite-only-actions">
          <button className="text-button" type="button" onClick={onSignOut} disabled={authState.loading}><SignOut size={18} />退出当前账号</button>
        </div>
      </section>
    </main>
  );
}
