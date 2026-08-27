import { useState } from "react";
import { AppleLogo } from "@phosphor-icons/react/AppleLogo";
import { Barn } from "@phosphor-icons/react/Barn";
import { CheckCircle } from "@phosphor-icons/react/CheckCircle";
import { CloudArrowDown } from "@phosphor-icons/react/CloudArrowDown";
import { CloudCheck } from "@phosphor-icons/react/CloudCheck";
import { CloudSlash } from "@phosphor-icons/react/CloudSlash";
import { Gear } from "@phosphor-icons/react/Gear";
import { LockKey } from "@phosphor-icons/react/LockKey";
import { SignIn } from "@phosphor-icons/react/SignIn";
import { SignOut } from "@phosphor-icons/react/SignOut";
import { UsersThree } from "@phosphor-icons/react/UsersThree";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";
import { PageTop } from "./FeaturePageShared.jsx";

const capabilityRows = [
  ["读取牧场", "可用", "可用", "可用"],
  ["记录生产", "可用", "可用", "可用"],
  ["修改历史事实", "可用", "可用", "受限"],
  ["管理基础目录", "可用", "可用", "受限"],
  ["查看洞察", "可用", "可用", "按授权"],
  ["删除受保护事实", "可用", "受限", "不可用"],
  ["管理成员与牧场", "可用", "受限", "不可用"],
];

export default function SettingsPage({ workspace, authState, isConfigured, onSignIn, onAppleSignIn, onSignOut, onReloadCloud }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [appleBusy, setAppleBusy] = useState(false);
  const [message, setMessage] = useState("");

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setMessage("");
    try {
      await onSignIn(email, password);
      setPassword("");
      setMessage("已登录并载入云端牧场。");
    } catch (error) {
      setMessage(error.message || "登录失败，请检查账号信息。");
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

  return (
    <main className="page feature-page">
      <PageTop title="设置" description="账号、牧场权限、云端数据与网页端安全边界。" icon={Gear} />
      <div className="settings-grid">
        <section className="workspace-panel cloud-settings-card">
          <div className="panel-heading"><h2>Supabase 云端</h2>{workspace.mode === "cloud" ? <CloudCheck size={25} className="success-icon" /> : <CloudSlash size={25} />}</div>
          {workspace.mode === "cloud" ? (
            <div className="signed-in-state">
              <div className="connection-summary"><CloudCheck size={34} /><span><strong>已连接 {workspace.farm.name}</strong><small>{workspace.profile?.email} · {workspace.farm.roleName}</small></span></div>
              <dl><div><dt>云端修订</dt><dd>#{workspace.farm.revision?.toLocaleString("zh-CN")}</dd></div><div><dt>权限策略</dt><dd>RLS 已启用</dd></div><div><dt>当前模式</dt><dd>读取基础投影</dd></div></dl>
              <div className="settings-actions"><button type="button" className="secondary-button" onClick={onReloadCloud}><CloudArrowDown size={19} />刷新云端</button><button type="button" className="text-danger-button" onClick={onSignOut}><SignOut size={19} />退出登录</button></div>
            </div>
          ) : (
            <form className="auth-form" onSubmit={submit}>
              <p>{isConfigured ? "使用与 App 相同的账号登录；浏览器只持有可公开的 publishable key，数据访问由 RLS 决定。" : "当前未配置 Supabase 浏览器环境。"}</p>
              <label>邮箱<input type="email" required value={email} onChange={(event) => setEmail(event.target.value)} autoComplete="username" disabled={!isConfigured || busy} /></label>
              <label>密码<input type="password" required value={password} onChange={(event) => setPassword(event.target.value)} autoComplete="current-password" disabled={!isConfigured || busy} /></label>
              <button className="primary-button" type="submit" disabled={!isConfigured || busy}><SignIn size={20} />{busy ? "正在登录…" : "登录云端账号"}</button>
              <div className="auth-divider" aria-hidden="true"><span>或</span></div>
              <button className="apple-auth-button" type="button" onClick={submitApple} disabled={!isConfigured || busy || appleBusy}>
                <AppleLogo size={20} weight="fill" />
                {appleBusy ? "正在跳转 Apple…" : "使用 Apple 登录"}
              </button>
              <small className="auth-provider-note">使用 Supabase Apple OAuth；登录后会返回当前网页。Apple Provider 需要先配置 Apple Developer secret。</small>
              {message || authState.error ? <div className="form-message">{message || authState.error}</div> : null}
            </form>
          )}
        </section>

        <section className="workspace-panel security-boundary-card">
          <div className="panel-heading"><h2>网页写入边界</h2><LockKey size={24} /></div>
          <div className="boundary-list">
            <article><CheckCircle size={22} weight="fill" /><span><strong>真实云端读取</strong><small>登录后按成员身份、牧场和 RLS 读取投影与事件。</small></span></article>
            <article><CheckCircle size={22} weight="fill" /><span><strong>本地交互草稿</strong><small>录入、筛选、表格和 TMR 操作在网页内立即可验证。</small></span></article>
            <article className="pending"><WarningCircle size={22} weight="fill" /><span><strong>生产云写入仍受保护</strong><small>完整移植命令校验、设备身份、修订冲突、Outbox 与远端重放前，不伪装成“已提交”。</small></span></article>
          </div>
        </section>

        <section className="workspace-panel capability-card">
          <div className="panel-heading"><h2>角色能力</h2><UsersThree size={24} /></div>
          <div className="table-scroll"><table className="data-table compact-capability"><thead><tr><th>能力</th><th>所有者</th><th>管理员</th><th>成员</th></tr></thead><tbody>{capabilityRows.map((row) => <tr key={row[0]}>{row.map((cell, index) => <td key={`${row[0]}-${index}`}>{index === 0 ? <strong>{cell}</strong> : cell}</td>)}</tr>)}</tbody></table></div>
        </section>

        <section className="workspace-panel farm-summary-card">
          <div className="panel-heading"><h2>当前牧场</h2><Barn size={24} /></div>
          <dl className="farm-summary-list"><div><dt>名称</dt><dd>{workspace.farm.name}</dd></div><div><dt>数据来源</dt><dd>{workspace.mode === "cloud" ? "Supabase 基础投影；规则/TMR 为预览" : "本地演示数据"}</dd></div><div><dt>在场羊只</dt><dd>{workspace.metrics.activeSheep.toLocaleString("zh-CN")} 只</dd></div><div><dt>有效圈舍</dt><dd>{workspace.metrics.activePens.toLocaleString("zh-CN")} 个</dd></div>{workspace.mode === "cloud" && workspace.projectionCoverage?.incompleteSheep ? <div><dt>资料未展开</dt><dd>{workspace.projectionCoverage.incompleteSheep.toLocaleString("zh-CN")} 只</dd></div> : null}</dl>
        </section>
      </div>
    </main>
  );
}
