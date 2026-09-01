import { useEffect, useMemo, useState } from "react";
import { ArrowsLeftRight } from "@phosphor-icons/react/ArrowsLeftRight";
import { Baby } from "@phosphor-icons/react/Baby";
import { BowlFood } from "@phosphor-icons/react/BowlFood";
import { Heart } from "@phosphor-icons/react/Heart";
import { Notebook } from "@phosphor-icons/react/Notebook";
import { Scales } from "@phosphor-icons/react/Scales";
import { SignOut } from "@phosphor-icons/react/SignOut";
import { Tag } from "@phosphor-icons/react/Tag";
import { UsersThree } from "@phosphor-icons/react/UsersThree";
import { X } from "@phosphor-icons/react/X";

const typeOptions = [
  { id: "addSheep", label: "新建羊只", icon: Tag },
  { id: "weight", label: "称重", icon: Scales },
  { id: "transfer", label: "转群", icon: ArrowsLeftRight },
  { id: "removal", label: "离场", icon: SignOut },
  { id: "feed", label: "记录投喂", icon: BowlFood },
  { id: "health", label: "治疗 / 疫苗", icon: Heart },
  { id: "note", label: "现场备注", icon: Notebook },
  { id: "reproduction", label: "配种 / 孕检", icon: Baby },
  { id: "lambing", label: "产羔", icon: Baby },
  { id: "weaning", label: "断奶", icon: UsersThree },
];

function localDateValue() {
  const date = new Date();
  date.setMinutes(date.getMinutes() - date.getTimezoneOffset());
  return date.toISOString().slice(0, 16);
}

const initialValues = {
  earTag: "",
  breed: "湖羊",
  sex: "母",
  sheep: "",
  pen: "",
  kilograms: "",
  meal: "早",
  recipe: "",
  healthKind: "治疗",
  itemName: "",
  removalKind: "出售",
  reason: "",
  reproductionKind: "配种",
  result: "",
  occurredAt: localDateValue(),
  note: "",
};

function Field({ label, children, hint }) {
  return (
    <label className="record-field">
      <span>{label}</span>
      {children}
      {hint ? <small>{hint}</small> : null}
    </label>
  );
}

function OptionSelect({ value, onChange, children, required = false }) {
  return <select value={value} onChange={(event) => onChange(event.target.value)} required={required}>{children}</select>;
}

function RecordFields({ type, values, setValue, workspace }) {
  const sheepOptions = workspace.sheep.slice(0, 100);
  const penOptions = workspace.pens.slice(0, 100);

  if (type === "addSheep") {
    return (
      <>
        <div className="form-grid two-columns">
          <Field label="耳号"><input autoFocus required value={values.earTag} onChange={(event) => setValue("earTag", event.target.value)} placeholder="例如 24031" /></Field>
          <Field label="品种"><input required value={values.breed} onChange={(event) => setValue("breed", event.target.value)} /></Field>
          <Field label="性别"><OptionSelect value={values.sex} onChange={(value) => setValue("sex", value)}><option>母</option><option>公</option></OptionSelect></Field>
          <Field label="初始圈舍"><OptionSelect value={values.pen} onChange={(value) => setValue("pen", value)}><option value="">未分圈</option>{penOptions.map((pen) => <option key={pen.id}>{pen.name}</option>)}</OptionSelect></Field>
        </div>
        <Field label="入场日期"><input type="datetime-local" required value={values.occurredAt} onChange={(event) => setValue("occurredAt", event.target.value)} /></Field>
      </>
    );
  }

  if (type === "weight") {
    return (
      <div className="form-grid two-columns">
        <Field label="羊只耳号"><OptionSelect required value={values.sheep} onChange={(value) => setValue("sheep", value)}><option value="">请选择</option>{sheepOptions.map((sheep) => <option key={sheep.id}>{sheep.earTag}</option>)}</OptionSelect></Field>
        <Field label="体重（kg）"><input autoFocus type="number" min="0.1" step="0.1" required value={values.kilograms} onChange={(event) => setValue("kilograms", event.target.value)} placeholder="例如 42.6" /></Field>
        <Field label="称重时间"><input type="datetime-local" required value={values.occurredAt} onChange={(event) => setValue("occurredAt", event.target.value)} /></Field>
      </div>
    );
  }

  if (type === "transfer") {
    return (
      <div className="form-grid two-columns">
        <Field label="羊只耳号"><OptionSelect required value={values.sheep} onChange={(value) => setValue("sheep", value)}><option value="">请选择</option>{sheepOptions.map((sheep) => <option key={sheep.id}>{sheep.earTag}</option>)}</OptionSelect></Field>
        <Field label="转入圈舍"><OptionSelect required value={values.pen} onChange={(value) => setValue("pen", value)}><option value="">请选择</option>{penOptions.map((pen) => <option key={pen.id}>{pen.name}</option>)}</OptionSelect></Field>
        <Field label="发生时间"><input type="datetime-local" required value={values.occurredAt} onChange={(event) => setValue("occurredAt", event.target.value)} /></Field>
      </div>
    );
  }

  if (type === "removal") {
    return (
      <div className="form-grid two-columns">
        <Field label="羊只耳号"><OptionSelect required value={values.sheep} onChange={(value) => setValue("sheep", value)}><option value="">请选择</option>{sheepOptions.map((sheep) => <option key={sheep.id}>{sheep.earTag}</option>)}</OptionSelect></Field>
        <Field label="离场类型"><OptionSelect value={values.removalKind} onChange={(value) => setValue("removalKind", value)}><option>出售</option><option>死亡</option><option>淘汰</option><option>其他</option></OptionSelect></Field>
        <Field label="原因"><input required value={values.reason} onChange={(event) => setValue("reason", event.target.value)} placeholder="请填写真实原因" /></Field>
        <Field label="发生时间"><input type="datetime-local" required value={values.occurredAt} onChange={(event) => setValue("occurredAt", event.target.value)} /></Field>
      </div>
    );
  }

  if (type === "feed") {
    return (
      <div className="form-grid two-columns">
        <Field label="圈舍"><OptionSelect required value={values.pen} onChange={(value) => setValue("pen", value)}><option value="">请选择</option>{penOptions.map((pen) => <option key={pen.id}>{pen.name}</option>)}</OptionSelect></Field>
        <Field label="顿次" hint="使用受控选项，避免历史统计被自由文本拆散。"><OptionSelect value={values.meal} onChange={(value) => setValue("meal", value)}><option>早</option><option>中</option><option>晚</option><option>全天</option></OptionSelect></Field>
        <Field label="配方"><OptionSelect required value={values.recipe} onChange={(value) => setValue("recipe", value)}><option value="">请选择</option>{workspace.recipes.map((recipe) => <option key={recipe.id}>{recipe.name}</option>)}</OptionSelect></Field>
        <Field label="实际投喂（kg）"><input type="number" min="0.1" step="0.1" required value={values.kilograms} onChange={(event) => setValue("kilograms", event.target.value)} /></Field>
        <Field label="发生时间"><input type="datetime-local" required value={values.occurredAt} onChange={(event) => setValue("occurredAt", event.target.value)} /></Field>
      </div>
    );
  }

  if (type === "health") {
    return (
      <div className="form-grid two-columns">
        <Field label="羊只耳号"><OptionSelect required value={values.sheep} onChange={(value) => setValue("sheep", value)}><option value="">请选择</option>{sheepOptions.map((sheep) => <option key={sheep.id}>{sheep.earTag}</option>)}</OptionSelect></Field>
        <Field label="记录类型"><OptionSelect value={values.healthKind} onChange={(value) => setValue("healthKind", value)}><option>治疗</option><option>疫苗</option><option>驱虫</option><option>检查</option></OptionSelect></Field>
        <Field label="项目名称"><input required value={values.itemName} onChange={(event) => setValue("itemName", event.target.value)} placeholder="例如 羊痘疫苗" /></Field>
        <Field label="发生时间"><input type="datetime-local" required value={values.occurredAt} onChange={(event) => setValue("occurredAt", event.target.value)} /></Field>
      </div>
    );
  }

  if (type === "note") {
    return (
      <div className="form-grid two-columns">
        <Field label="关联羊只（可选）"><OptionSelect value={values.sheep} onChange={(value) => setValue("sheep", value)}><option value="">不关联羊只</option>{sheepOptions.map((sheep) => <option key={sheep.id}>{sheep.earTag}</option>)}</OptionSelect></Field>
        <Field label="发生时间"><input type="datetime-local" required value={values.occurredAt} onChange={(event) => setValue("occurredAt", event.target.value)} /></Field>
      </div>
    );
  }

  if (type === "weaning") {
    return (
      <div className="form-grid two-columns">
        <Field label="羔羊耳号"><OptionSelect required value={values.sheep} onChange={(value) => setValue("sheep", value)}><option value="">请选择</option>{sheepOptions.map((sheep) => <option key={sheep.id}>{sheep.earTag}</option>)}</OptionSelect></Field>
        <Field label="断奶后圈舍"><OptionSelect required value={values.pen} onChange={(value) => setValue("pen", value)}><option value="">请选择</option>{penOptions.map((pen) => <option key={pen.id}>{pen.name}</option>)}</OptionSelect></Field>
        <Field label="断奶时间"><input type="datetime-local" required value={values.occurredAt} onChange={(event) => setValue("occurredAt", event.target.value)} /></Field>
      </div>
    );
  }

  if (type === "lambing") {
    return (
      <div className="form-grid two-columns">
        <Field label="母羊耳号"><OptionSelect required value={values.sheep} onChange={(value) => setValue("sheep", value)}><option value="">请选择</option>{sheepOptions.filter((sheep) => sheep.sex === "母").map((sheep) => <option key={sheep.id}>{sheep.earTag}</option>)}</OptionSelect></Field>
        <Field label="产羔结果"><input required value={values.result} onChange={(event) => setValue("result", event.target.value)} placeholder="例如 活羔 2 只" /></Field>
        <Field label="发生时间"><input type="datetime-local" required value={values.occurredAt} onChange={(event) => setValue("occurredAt", event.target.value)} /></Field>
      </div>
    );
  }

  return (
    <div className="form-grid two-columns">
      <Field label="母羊耳号"><OptionSelect required value={values.sheep} onChange={(value) => setValue("sheep", value)}><option value="">请选择</option>{sheepOptions.filter((sheep) => sheep.sex === "母").map((sheep) => <option key={sheep.id}>{sheep.earTag}</option>)}</OptionSelect></Field>
      <Field label="繁殖事件"><OptionSelect value={values.reproductionKind} onChange={(value) => setValue("reproductionKind", value)}><option>配种</option><option>孕检</option><option>产羔</option><option>断奶</option></OptionSelect></Field>
      <Field label="结果"><input required value={values.result} onChange={(event) => setValue("result", event.target.value)} placeholder="例如 已配种 / 阳性 / 2 只" /></Field>
      <Field label="发生时间"><input type="datetime-local" required value={values.occurredAt} onChange={(event) => setValue("occurredAt", event.target.value)} /></Field>
    </div>
  );
}

function eventSummary(type, values) {
  switch (type) {
    case "addSheep": return { label: "新建羊只", object: `羊只 ${values.earTag}`, eventType: "note" };
    case "weight": return { label: "称重完成", object: `羊只 ${values.sheep} · ${values.kilograms} kg`, eventType: "weight" };
    case "transfer": return { label: "转群完成", object: `羊只 ${values.sheep} → ${values.pen}`, eventType: "transfer" };
    case "removal": return { label: "离场记录", object: `羊只 ${values.sheep} · ${values.removalKind}`, eventType: "note" };
    case "feed": return { label: "记录投喂", object: `${values.pen} · ${values.meal}`, eventType: "feed" };
    case "health": return { label: "健康记录", object: `羊只 ${values.sheep} · ${values.itemName}`, eventType: "health" };
    case "note": return { label: "现场备注", object: values.sheep ? `羊只 ${values.sheep} · ${values.note}` : values.note, eventType: "note" };
    case "weaning": return { label: "断奶记录", object: `羊只 ${values.sheep} → ${values.pen}`, eventType: "reproduction" };
    case "lambing": return { label: "产羔记录", object: `母羊 ${values.sheep} · ${values.result}`, eventType: "reproduction" };
    default: return { label: values.reproductionKind, object: `母羊 ${values.sheep}`, eventType: "reproduction" };
  }
}

export function RecordDialog({ open, requestedType, workspace, onClose, onSubmit }) {
  const [type, setType] = useState(requestedType === "new" ? null : requestedType);
  const [values, setValues] = useState(initialValues);

  useEffect(() => {
    if (!open) return undefined;
    setType(requestedType === "new" ? null : requestedType);
    setValues({ ...initialValues, occurredAt: localDateValue() });
    function onKeyDown(event) {
      if (event.key === "Escape") onClose();
    }
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [onClose, open, requestedType]);

  const selected = useMemo(() => typeOptions.find((option) => option.id === type), [type]);

  if (!open) return null;

  function setValue(key, value) {
    setValues((current) => ({ ...current, [key]: value }));
  }

  function submit(event) {
    event.preventDefault();
    const summary = eventSummary(type, values);
    onSubmit({
      ...summary,
      type,
      occurredAt: new Date(values.occurredAt).toISOString(),
      values,
    });
  }

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
      <section className="record-dialog" role="dialog" aria-modal="true" aria-labelledby="record-dialog-title">
        <header>
          <span><h2 id="record-dialog-title">{selected?.label ?? "新建记录"}</h2><p>先在网页形成可核对草稿；尚不会伪装成云端已提交。</p></span>
          <button type="button" className="icon-button" onClick={onClose} aria-label="关闭"><X size={23} /></button>
        </header>

        {!type ? (
          <div className="record-type-grid">
            {typeOptions.map(({ id, label, icon: Icon }) => (
              <button type="button" key={id} onClick={() => setType(id)}><Icon size={31} /><span>{label}</span></button>
            ))}
          </div>
        ) : (
          <form onSubmit={submit}>
            <RecordFields type={type} values={values} setValue={setValue} workspace={workspace} />
            <Field label={type === "note" ? "现场备注" : "备注"}><textarea required={type === "note"} rows="3" value={values.note} onChange={(event) => setValue("note", event.target.value)} placeholder={type === "note" ? "请填写需要保留的现场事实" : "可选；只记录与本次业务事实相关的信息"} /></Field>
            <footer>
              {requestedType === "new" ? <button className="text-button" type="button" onClick={() => setType(null)}>返回选择</button> : <span />}
              <div><button className="secondary-button" type="button" onClick={onClose}>取消</button><button className="primary-button" type="submit">确认记录</button></div>
            </footer>
          </form>
        )}
      </section>
    </div>
  );
}
