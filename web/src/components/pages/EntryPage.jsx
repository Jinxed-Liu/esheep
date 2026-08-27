import { ArrowsLeftRight } from "@phosphor-icons/react/ArrowsLeftRight";
import { Baby } from "@phosphor-icons/react/Baby";
import { Heart } from "@phosphor-icons/react/Heart";
import { Plus } from "@phosphor-icons/react/Plus";
import { SignOut } from "@phosphor-icons/react/SignOut";
import { SheepGlyph as Sheep, WeightGlyph as Scale } from "../DomainIcons.jsx";
import { formatDateTime, PageTop } from "./FeaturePageShared.jsx";

const entryGroups = [
  { id: "addSheep", title: "羊只建档", text: "创建耳号、品种、性别、入场与出生基线。", icon: Sheep },
  { id: "weight", title: "称重", text: "记录真实称重日期与体重，不覆盖历史。", icon: Scale },
  { id: "transfer", title: "转群", text: "按发生日期将羊只转入目标圈舍。", icon: ArrowsLeftRight },
  { id: "removal", title: "离场", text: "出售、死亡或淘汰，并保留可纠正事件。", icon: SignOut },
  { id: "health", title: "健康与免疫", text: "用药、疫苗、治疗与库存扣减。", icon: Heart },
  { id: "reproduction", title: "繁殖", text: "配种、孕检、产羔、断奶和系谱事实。", icon: Baby },
];

export default function EntryPage({ workspace, onCreateRecord }) {
  const timeZone = workspace.farm?.timeZoneIdentifier || "Asia/Shanghai";
  return (
    <main className="page feature-page">
      <PageTop title="生产录入" description="每次录入都先形成可确认的业务动作，再进入事件历史。" />
      <div className="entry-layout">
        <section className="entry-action-list">
          {entryGroups.map(({ id, title, text, icon: Icon }) => (
            <button type="button" key={id} onClick={() => onCreateRecord(id)}>
              <Icon size={28} />
              <span><strong>{title}</strong><small>{text}</small></span>
              <Plus size={21} />
            </button>
          ))}
        </section>
        <aside className="workspace-panel entry-history">
          <div className="panel-heading"><h2>{workspace.mode === "cloud" ? "已同步事件" : "今日已录入"}</h2><span>{workspace.events.length} 条</span></div>
          <div className="simple-activity-list">
            {workspace.events.slice(0, 7).map((event) => (
              <article key={event.id}>
                <span className={`activity-mark ${event.status}`} />
                <div><strong>{event.label}</strong><small>{event.object} · {event.actor}</small></div>
                <time>{formatDateTime(event.at, timeZone)}</time>
              </article>
            ))}
          </div>
        </aside>
      </div>
    </main>
  );
}
