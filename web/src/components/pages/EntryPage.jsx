import { ArrowsLeftRight } from "@phosphor-icons/react/ArrowsLeftRight";
import { Baby } from "@phosphor-icons/react/Baby";
import { CaretRight } from "@phosphor-icons/react/CaretRight";
import { Factory } from "@phosphor-icons/react/Factory";
import { FirstAidKit } from "@phosphor-icons/react/FirstAidKit";
import { Notebook } from "@phosphor-icons/react/Notebook";
import { Scales } from "@phosphor-icons/react/Scales";
import { SignOut } from "@phosphor-icons/react/SignOut";
import { Tag } from "@phosphor-icons/react/Tag";
import { UsersThree } from "@phosphor-icons/react/UsersThree";
import { formatDateTime, PageTop } from "./FeaturePageShared.jsx";

const recordGroups = [
  {
    title: "日常记录",
    subtitle: "体重、护理与现场备注",
    items: [
      { id: "weight", label: "称重", detail: "追加真实称重日期与体重", icon: Scales },
      { id: "health", label: "治疗 / 疫苗", detail: "治疗、疫苗、驱虫与检查", icon: FirstAidKit },
      { id: "note", label: "现场备注", detail: "记录与生产事实相关的说明", icon: Notebook },
    ],
  },
  {
    title: "羊只流转",
    subtitle: "建档、转群、断奶与离场",
    items: [
      { id: "addSheep", label: "新增羊只", detail: "建立耳号、品种与出生基线", icon: Tag },
      { id: "transfer", label: "转群", detail: "将羊只转入目标圈舍", icon: ArrowsLeftRight },
      { id: "weaning", label: "断奶", detail: "记录母羔关系与断奶时间", icon: UsersThree },
      { id: "removal", label: "出售 / 淘汰 / 死亡", detail: "保留离场类型、原因与日期", icon: SignOut },
    ],
  },
  {
    title: "繁殖",
    subtitle: "配种、孕检与产羔",
    items: [
      { id: "reproduction", label: "配种 / 孕检", detail: "记录配种事实或检查结果", icon: Baby },
      { id: "lambing", label: "产羔", detail: "记录产羔结果并关联羔羊", icon: Baby },
    ],
  },
];

const managementItems = [
  { id: "batches", label: "生产批次", detail: "育肥、后备与产羔批次", icon: Factory },
  { id: "care", label: "护理管理", detail: "药品、疫苗与库存预警", icon: FirstAidKit },
  { id: "events", label: "事件历史与导出", detail: "审计、筛选和导出业务事件", icon: Notebook },
];

export default function EntryPage({ workspace, onCreateRecord, onNavigate }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  return (
    <main className="page feature-page">
      <PageTop title="录入" description="与 App 一致：先选业务动作，再形成可追溯事件；云端写入边界会在确认前明确说明。" />
      <div className="record-hub-layout">
        <div className="record-group-stack">
          {recordGroups.map((group) => (
            <section className="record-hub-group" key={group.title}>
              <div className="group-heading"><span><h2>{group.title}</h2><p>{group.subtitle}</p></span></div>
              <div className="hub-action-grid">
                {group.items.map(({ id, label, detail, icon: Icon }) => (
                  <button type="button" key={id} onClick={() => onCreateRecord(id)}>
                    <span className="hub-action-icon"><Icon size={24} /></span>
                    <span><strong>{label}</strong><small>{detail}</small></span>
                    <CaretRight size={18} weight="bold" />
                  </button>
                ))}
              </div>
            </section>
          ))}

          <section className="record-hub-group">
            <div className="group-heading"><span><h2>管理</h2><p>批次、护理与事件历史</p></span></div>
            <div className="management-action-list">
              {managementItems.map(({ id, label, detail, icon: Icon }) => (
                <button type="button" key={id} onClick={() => onNavigate(id)}>
                  <Icon size={23} />
                  <span><strong>{label}</strong><small>{detail}</small></span>
                  <CaretRight size={18} weight="bold" />
                </button>
              ))}
            </div>
          </section>
        </div>

        <aside className="recent-records-panel">
          <div className="side-section-title split-title"><span><p className="eyebrow">RECENT</p><h2>最近事件</h2></span><button type="button" onClick={() => onNavigate("events")}>全部</button></div>
          <div className="recent-event-list">
            {workspace.events.slice(0, 8).map((event) => (
              <button type="button" key={event.id} onClick={() => onNavigate("events", { selectedID: event.id })}>
                <span className={`event-status-dot ${event.status}`} />
                <span><strong>{event.label}</strong><small>{event.object} · {event.actor}</small><time>{formatDateTime(event.at, timeZone)}</time></span>
                <CaretRight size={17} weight="bold" />
              </button>
            ))}
          </div>
        </aside>
      </div>
    </main>
  );
}
