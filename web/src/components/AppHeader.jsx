import { useEffect, useRef, useState } from "react";
import { BowlFood } from "@phosphor-icons/react/BowlFood";
import { CaretDown } from "@phosphor-icons/react/CaretDown";
import { Check } from "@phosphor-icons/react/Check";
import { CloudCheck } from "@phosphor-icons/react/CloudCheck";
import { CloudSlash } from "@phosphor-icons/react/CloudSlash";
import { House } from "@phosphor-icons/react/House";
import { MagnifyingGlass } from "@phosphor-icons/react/MagnifyingGlass";
import { PencilSimpleLine } from "@phosphor-icons/react/PencilSimpleLine";
import { Robot } from "@phosphor-icons/react/Robot";
import { SignOut } from "@phosphor-icons/react/SignOut";
import { Sparkle } from "@phosphor-icons/react/Sparkle";
import { UserCircle } from "@phosphor-icons/react/UserCircle";

export const NAV_ITEMS = [
  { id: "home", label: "首页", icon: House },
  { id: "insights", label: "洞察", icon: Sparkle },
  { id: "entry", label: "录入", icon: PencilSimpleLine },
  { id: "feeding", label: "投喂", icon: BowlFood },
  { id: "search", label: "搜索", icon: MagnifyingGlass },
];

const pageParents = {
  home: "home",
  flock: "home",
  pens: "home",
  alerts: "home",
  insights: "insights",
  assistant: "insights",
  entry: "entry",
  care: "entry",
  batches: "entry",
  events: "entry",
  feeding: "feeding",
  "feed-history": "feeding",
  ingredients: "feeding",
  tmr: "feeding",
  "tmr-feed": "feeding",
  "tmr-produce": "feeding",
  "tmr-batches": "feeding",
  "tmr-monitor": "feeding",
  "tmr-plans": "feeding",
  "tmr-formulas": "feeding",
  search: "search",
};

export function primaryPageFor(page) {
  return pageParents[page] ?? page;
}

function useOutsideDismiss(ref, dismiss) {
  useEffect(() => {
    function handlePointerDown(event) {
      if (ref.current && !ref.current.contains(event.target)) dismiss();
    }
    document.addEventListener("pointerdown", handlePointerDown);
    return () => document.removeEventListener("pointerdown", handlePointerDown);
  }, [dismiss, ref]);
}

export function AppHeader({
  activePage,
  onNavigate,
  workspace,
  onFarmChange,
  onSignOut,
}) {
  const [farmMenuOpen, setFarmMenuOpen] = useState(false);
  const [accountMenuOpen, setAccountMenuOpen] = useState(false);
  const farmMenuRef = useRef(null);
  const accountMenuRef = useRef(null);
  const activePrimaryPage = primaryPageFor(activePage);
  const personName = workspace.profile?.displayName ?? "牧场成员";

  useOutsideDismiss(farmMenuRef, () => setFarmMenuOpen(false));
  useOutsideDismiss(accountMenuRef, () => setAccountMenuOpen(false));

  return (
    <>
      <aside className="app-sidebar" aria-label="eSheepNext 主要导航">
        <button className="sidebar-brand" type="button" onClick={() => onNavigate("home")} aria-label="返回首页">
          <img src="/assets/esheepnext-mark.png" alt="" />
          <span>eSheepNext</span>
        </button>

        <nav className="sidebar-nav">
          {NAV_ITEMS.map(({ id, label, icon: Icon }) => (
            <button
              key={id}
              type="button"
              className={activePrimaryPage === id ? "active" : ""}
              aria-current={activePrimaryPage === id ? "page" : undefined}
              onClick={() => onNavigate(id)}
            >
              <Icon size={24} weight={activePrimaryPage === id ? "fill" : "regular"} />
              <span>{label}</span>
            </button>
          ))}
        </nav>

        <div className={`sidebar-sync ${workspace.mode === "cloud" ? "cloud" : "demo"}`}>
          {workspace.mode === "cloud" ? <CloudCheck size={18} weight="fill" /> : <CloudSlash size={18} />}
          <span>{workspace.mode === "cloud" ? "云端读取已连接" : "演示工作区"}</span>
        </div>
      </aside>

      <header className="app-topbar">
        <div className="farm-switcher" ref={farmMenuRef}>
          <button
            className="farm-switcher-button"
            type="button"
            aria-expanded={farmMenuOpen}
            onClick={() => setFarmMenuOpen((open) => !open)}
          >
            <House size={18} weight="duotone" />
            <span>{workspace.farm.name}</span>
            <CaretDown size={16} weight="bold" />
          </button>
          {farmMenuOpen ? (
            <div className="popover farm-menu" role="menu">
              <p className="popover-label">选择牧场</p>
              {workspace.farms.map((farm) => (
                <button
                  key={farm.id}
                  type="button"
                  className="farm-menu-item"
                  onClick={() => {
                    onFarmChange(farm.id);
                    setFarmMenuOpen(false);
                  }}
                >
                  <span>
                    <strong>{farm.name}</strong>
                    <small>{farm.roleName ?? (farm.role === "owner" ? "所有者" : "管理员")}</small>
                  </span>
                  {farm.id === workspace.farm.id ? <Check size={18} weight="bold" /> : null}
                </button>
              ))}
            </div>
          ) : null}
        </div>

        <div className="topbar-actions">
          <button
            className={`topbar-assistant-button${activePage === "assistant" ? " active" : ""}`}
            type="button"
            onClick={() => onNavigate("assistant")}
            aria-current={activePage === "assistant" ? "page" : undefined}
            aria-label="Codex 助手"
          >
            <Robot size={20} weight={activePage === "assistant" ? "fill" : "duotone"} />
            <span>Codex 助手</span>
          </button>
          <div className="account-menu-wrap" ref={accountMenuRef}>
            <button
              className="account-button"
              type="button"
              onClick={() => setAccountMenuOpen((open) => !open)}
              aria-expanded={accountMenuOpen}
              aria-label={`${personName}账户菜单`}
            >
              <img src="/assets/mimo-assistant.png" alt="" />
              <span>{personName}</span>
              <CaretDown size={15} weight="bold" />
            </button>
            {accountMenuOpen ? (
              <div className="popover account-menu">
                <div className="account-summary">
                  <img src="/assets/mimo-assistant.png" alt="" />
                  <span>
                    <strong>{personName}</strong>
                    <small>{workspace.profile?.email ?? "当前演示账户"}</small>
                  </span>
                </div>
                <button type="button" onClick={() => { onNavigate("settings"); setAccountMenuOpen(false); }}>
                  <UserCircle size={19} />
                  账户与牧场设置
                </button>
                {workspace.mode === "cloud" ? (
                  <button type="button" onClick={() => { onSignOut(); setAccountMenuOpen(false); }}>
                    <SignOut size={19} />
                    退出云端账号
                  </button>
                ) : null}
              </div>
            ) : null}
          </div>
        </div>
      </header>
    </>
  );
}
