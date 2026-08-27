import { Plus } from "@phosphor-icons/react/Plus";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";

export function PageTop({ title, description, actionLabel, onAction, icon: Icon = Plus }) {
  return (
    <header className="feature-page-top">
      <span>
        <h1>{title}</h1>
        <p>{description}</p>
      </span>
      {actionLabel ? (
        <button className="primary-button" type="button" onClick={onAction}>
          <Icon size={20} />
          {actionLabel}
        </button>
      ) : null}
    </header>
  );
}

export function Segmented({ items, value, onChange }) {
  return (
    <div className="segmented" role="tablist">
      {items.map((item) => (
        <button
          type="button"
          role="tab"
          aria-selected={value === item.id}
          className={value === item.id ? "active" : ""}
          key={item.id}
          onClick={() => onChange(item.id)}
        >
          {item.label}
        </button>
      ))}
    </div>
  );
}

export function ProjectionNotice({ children }) {
  return <div className="projection-notice"><WarningCircle size={19} weight="fill" /><span>{children}</span></div>;
}

export function formatDateTime(value, timeZone = "Asia/Shanghai") {
  if (!value) return "—";
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone,
  }).format(new Date(value));
}
