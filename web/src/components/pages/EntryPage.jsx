import { useRef, useState } from "react";
import { ArrowsLeftRight } from "@phosphor-icons/react/ArrowsLeftRight";
import { Baby } from "@phosphor-icons/react/Baby";
import { CaretRight } from "@phosphor-icons/react/CaretRight";
import { CheckCircle } from "@phosphor-icons/react/CheckCircle";
import { DownloadSimple } from "@phosphor-icons/react/DownloadSimple";
import { Factory } from "@phosphor-icons/react/Factory";
import { FileXls } from "@phosphor-icons/react/FileXls";
import { FirstAidKit } from "@phosphor-icons/react/FirstAidKit";
import { Notebook } from "@phosphor-icons/react/Notebook";
import { Scales } from "@phosphor-icons/react/Scales";
import { SignOut } from "@phosphor-icons/react/SignOut";
import { Tag } from "@phosphor-icons/react/Tag";
import { UploadSimple } from "@phosphor-icons/react/UploadSimple";
import { UsersThree } from "@phosphor-icons/react/UsersThree";
import { WarningCircle } from "@phosphor-icons/react/WarningCircle";
import { formatDateTime, PageTop } from "./FeaturePageShared.jsx";

const excelTemplateVersion = 7;
const excelTemplateBase = `${import.meta.env.BASE_URL || "/"}downloads/eSheepPlus_全功能录入模板_v${excelTemplateVersion}`;

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
  const workbookInput = useRef(null);
  const [workbookState, setWorkbookState] = useState({ status: "idle", result: null, error: "" });

  async function inspectWorkbook(event) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    setWorkbookState({ status: "reading", result: null, error: "" });
    try {
      const { inspectExcelWorkbook } = await import("../../lib/excelWorkbook.js");
      const result = await inspectExcelWorkbook(file, `${excelTemplateBase}.json`);
      setWorkbookState({ status: result.issues.length ? "invalid" : "ready", result, error: "" });
    } catch (error) {
      setWorkbookState({ status: "invalid", result: null, error: error.message || "工作簿读取失败。" });
    }
  }

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

          <section className="record-hub-group excel-import-section">
            <div className="group-heading"><span><h2>Excel 批量录入</h2><p>与 App 共用 v{excelTemplateVersion} 模板和字段契约</p></span><FileXls size={27} /></div>
            <div className="excel-import-actions">
              <a className="secondary-button" href={`${excelTemplateBase}.xlsx`} download={`eSheepPlus_全功能录入模板_v${excelTemplateVersion}.xlsx`}><DownloadSimple size={19} />下载 App 同源模板</a>
              <button className="primary-button" type="button" onClick={() => workbookInput.current?.click()} disabled={workbookState.status === "reading"}><UploadSimple size={19} />{workbookState.status === "reading" ? "正在检查…" : "选择工作簿"}</button>
              <input ref={workbookInput} className="visually-hidden" type="file" accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" onChange={inspectWorkbook} />
            </div>
            <p className="excel-import-boundary">网页会先在本机检查模板版本、字段、必填项和重复导入键，不会把工作簿上传到第三方。生产云端提交仍必须经过与 App 等价的权限、业务校验、审计和 Outbox 管道。</p>
            {workbookState.error ? <div className="excel-preflight-result invalid"><WarningCircle size={21} weight="fill" /><span><strong>无法读取工作簿</strong><small>{workbookState.error}</small></span></div> : null}
            {workbookState.result ? (
              <div className={`excel-preflight-result ${workbookState.status}`}>
                {workbookState.status === "ready" ? <CheckCircle size={22} weight="fill" /> : <WarningCircle size={22} weight="fill" />}
                <span>
                  <strong>{workbookState.status === "ready" ? `结构预检通过 · App 模板 v${workbookState.result.version}` : "工作簿需要修正"}</strong>
                  <small>{workbookState.result.fileName}</small>
                  {workbookState.result.summaries.length ? <em>{workbookState.result.summaries.map((item) => `${item.name} ${item.rowCount} 行`).join(" · ")}</em> : null}
                  {workbookState.result.issues.slice(0, 6).map((issue) => <em className="issue" key={issue}>{issue}</em>)}
                  {workbookState.result.issues.length > 6 ? <em className="issue">另有 {workbookState.result.issues.length - 6} 项问题</em> : null}
                </span>
              </div>
            ) : null}
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
