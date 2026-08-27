import { useEffect, useRef, useState } from "react";
import { CaretDown } from "@phosphor-icons/react/CaretDown";
import { Check } from "@phosphor-icons/react/Check";
import { MagnifyingGlass } from "@phosphor-icons/react/MagnifyingGlass";
import { SignOut } from "@phosphor-icons/react/SignOut";
import { UserCircle } from "@phosphor-icons/react/UserCircle";

export const NAV_ITEMS = [
  { id: "home", label: "首页" },
  { id: "flock", label: "羊群" },
  { id: "entry", label: "录入" },
  { id: "feeding", label: "投喂" },
  { id: "tmr", label: "TMR" },
  { id: "insights", label: "洞察" },
  { id: "events", label: "事件记录" },
  { id: "settings", label: "设置" },
];

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
  query,
  onQueryChange,
  searchResults,
  onSearchResult,
  onSignOut,
}) {
  const [farmMenuOpen, setFarmMenuOpen] = useState(false);
  const [accountMenuOpen, setAccountMenuOpen] = useState(false);
  const farmMenuRef = useRef(null);
  const accountMenuRef = useRef(null);
  const searchRef = useRef(null);

  useOutsideDismiss(farmMenuRef, () => setFarmMenuOpen(false));
  useOutsideDismiss(accountMenuRef, () => setAccountMenuOpen(false));

  const personName = workspace.profile?.displayName ?? "MiMo 助手";

  return (
    <header className="app-header">
      <button className="brand" type="button" onClick={() => onNavigate("home")} aria-label="返回首页">
        <img src="/assets/esheepnext-mark.png" alt="" className="brand-mark" />
        <span>eSheepNext</span>
      </button>

      <div className="farm-switcher" ref={farmMenuRef}>
        <button
          className="farm-switcher-button"
          type="button"
          aria-expanded={farmMenuOpen}
          onClick={() => setFarmMenuOpen((open) => !open)}
        >
          <span>{workspace.farm.name}</span>
          <CaretDown size={17} weight="bold" />
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

      <nav className="primary-nav" aria-label="主要导航">
        {NAV_ITEMS.map((item) => (
          <button
            key={item.id}
            type="button"
            className={item.id === activePage ? "active" : ""}
            onClick={() => onNavigate(item.id)}
          >
            {item.label}
          </button>
        ))}
      </nav>

      <div className="header-tools">
        <div className="global-search" ref={searchRef}>
          <MagnifyingGlass size={20} aria-hidden="true" />
          <input
            value={query}
            onChange={(event) => onQueryChange(event.target.value)}
            placeholder="搜索耳号、品种或圈舍"
            aria-label="搜索羊只、品种或圈舍"
          />
          {query.trim() ? (
            <div className="popover search-results" role="listbox">
              <p className="popover-label">搜索结果</p>
              {searchResults.length ? (
                searchResults.slice(0, 8).map((result) => (
                  <button
                    type="button"
                    key={`${result.kind}-${result.id}`}
                    className="search-result-row"
                    onClick={() => onSearchResult(result)}
                  >
                    <span>{result.title}</span>
                    <small>{result.detail}</small>
                  </button>
                ))
              ) : (
                <div className="empty-search">未找到匹配记录</div>
              )}
            </div>
          ) : null}
        </div>

        <div className="account-menu-wrap" ref={accountMenuRef}>
          <button
            className="account-button"
            type="button"
            onClick={() => setAccountMenuOpen((open) => !open)}
            aria-expanded={accountMenuOpen}
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
                  <small>{workspace.profile?.email ?? "牧场智能助理"}</small>
                </span>
              </div>
              <button type="button" onClick={() => { onNavigate("settings"); setAccountMenuOpen(false); }}>
                <UserCircle size={19} />
                账号与设置
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
  );
}
