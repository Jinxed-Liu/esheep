import { additionalRecordSchemas } from './additionalRecordSchemas.js';
import { additionalBusinessCommands } from './additionalBusinessCommands.js';
import templateContract from "../../public/downloads/eSheepPlus_全功能录入模板_v7.json" with {type:"json"};
import { validateBusinessSpecifications,penAtTime,presentAtTime } from "./businessValidation.js";
import { stableUUID, liveRows } from "./nativeEventSnapshots.js";
import { farmDateText } from "./eventExport.js";

export const listValues = (value) => String(value ?? "").split(/[;；,，、\n]/).map((v) => v.trim()).filter(Boolean);
const earKey = value=>String(value??"").normalize("NFC").trim().toUpperCase();
const normalized = (value) => String(value ?? "").normalize("NFKC").trim().toLowerCase();
const nil = (value) => String(value ?? "").trim() || null;
const sex = (value) => ({ 母: "ewe", 母羊: "ewe", 公: "ram", 公羊: "ram", 未知: "unknown" })[value];
const health = (value) => ({ 治疗: "treatment", 疫苗: "vaccination" })[value];
const repro = (value) => ({ 配种: "breeding", 孕检: "pregnancyCheck", 流产: "abortion" })[value];
const removal = (value) => ({ 出售: "sold", 淘汰: "culled", 死亡: "deceased", 转出: "transferredOut" })[value];
const requireValue = (condition, message) => { if (!condition) throw new Error(message); };
function decimal(value, label, allowNegative = false, optional = false) {
  if (optional && !nil(value)) return null;
  const text = String(value ?? "").trim();
  requireValue(/^-?\d+(\.\d+)?$/.test(text) && Number.isFinite(Number(text)) && (allowNegative ? Number(text) !== 0 : Number(text) > 0), `${label}必须填写${allowNegative ? "非零" : "正"}数。`);
  return text;
}
function integer(value, label, minimum = 0, optional = false) {
  if (optional && !nil(value)) return null;
  requireValue(/^\d+$/.test(String(value)) && Number.isSafeInteger(Number(value)) && Number(value) >= minimum, `${label}必须是至少 ${minimum} 的整数。`);
  return Number(value);
}
export function parseBusinessDate(value, timeZone = "Asia/Shanghai", optional = false) {
  if (optional && !nil(value)) return null;
  let text = String(value ?? "").trim();
  // Excel's serial dates use 1899-12-30, including its historical leap-day bug.
  if (/^\d+(\.\d+)?$/.test(text)) text = new Date(Date.UTC(1899, 11, 30) + Number(text) * 86400000).toISOString().slice(0, 19);
  const match = /^(\d{4})-(\d\d)-(\d\d)(?:[T ](\d\d):(\d\d)(?::(\d\d))?)?$/.exec(text);
  requireValue(match, "日期请使用 yyyy-MM-dd 或 yyyy-MM-dd HH:mm:ss。");
  const [, y, m, d, hh = "00", mm = "00", ss = "00"] = match;
  const utc = Date.UTC(+y, +m - 1, +d, +hh, +mm, +ss);
  const desired = `${y}-${m}-${d} ${hh}:${mm}:${ss}`;
  let instant = utc;
  for (let i = 0; i < 3; i++) {
    const displayed = farmDateText(instant, timeZone).replace(" ", "T") + "Z";
    instant += utc - Date.parse(displayed);
  }
  requireValue(farmDateText(instant, timeZone) === desired, "日期或时刻不存在，请检查年月日与牧场时区。");
  return instant;
}

export async function buildBusinessCommands(record, workspace, { identity = record.importKey ?? record.id ?? crypto.randomUUID() } = {}) {
  const { sheet } = record;
  const v=Object.fromEntries(Object.entries(record.values??{}).map(([key,value])=>[key,String(value??"").trim()]));
  for(const key of [...templateContract.schemas,...additionalRecordSchemas].find(s=>s.name===sheet)?.required??[])if(key!=="导入键")requireValue(v[key],`${key}不能为空。`);
  requireValue(sheet && v, "记录缺少业务类型或字段。");
  const models = workspace.models;
  requireValue(models, "请先读取完整牧场资料再录入。");
  const timezone = workspace.farm.timeZoneIdentifier || "Asia/Shanghai";
  const id = await stableUUID(workspace.farm.id, `excel-v3:${sheet}:${String(identity).toLowerCase()}`);
  if(record.importKey&&Object.values(models).some(rows=>rows.some(row=>row.id===id)))throw new Error(`导入键 ${record.importKey} 已对应云端记录，请核对原记录，不能重复导入。`);
  const now = Date.now(), date = (field, optional = false) => parseBusinessDate(v[field], timezone, optional);
  const occurred = () => date("发生日期");
  const note = v["备注"] ?? "";
  const rows = (model) => liveRows(models, model);
  const find = (model, key, value, label, optional = false) => {
    if (!nil(value) && optional) return null;
    const found = rows(model).filter((r) => normalized(r[key]) === normalized(value));
    requireValue(found.length === 1, `${label}“${value ?? ""}”${found.length ? "不唯一，请先处理重名" : "不存在"}。`);
    return found[0];
  };
  const sheep = (tag, optional = false) => find("SheepRecord", "earTag", tag, "耳号", optional);
  const pen = (name, optional = false) => find("PenRecord", "name", name, "圈舍", optional);
  const ingredient = (name) => find("FeedIngredientRecord", "name", name, "原料");
  const recipe = (name, optional = false) => find("FeedRecipeRecord", "name", name, "配方", optional);
  const semen = (name, optional = false) => find("SemenRecord", "code", name, "冻精", optional);
  const donor = (name, optional = false) => find("SemenDonorRecord", "registrationNumber", name, "供体登记号", optional);
  const catalog = (name, optional = false) => find("HealthCatalogItemRecord", "name", name, "健康目录", optional);
  const lot = (name, batch) => {
    const found = rows("InventoryLotRecord").filter((r) => normalized(r.catalogName) === normalized(name) && normalized(r.batchNumber) === normalized(batch));
    requireValue(found.length === 1, `库存“${name} / ${batch}”不存在或不唯一。`); return found[0];
  };
  const targets = (field) => {
    const tags = listValues(v[field]);
    requireValue(tags.length > 0 && new Set(tags.map(normalized)).size === tags.length, `${field}不能为空或包含重复耳号。`);
    return tags.map((tag) => sheep(tag));
  };
  const breedingRam = (tag) => {
    const row = sheep(tag, true);
    requireValue(!row || row.sexRawValue === "ram" && row.isBreedingRam, "父本必须是已明确标记的种公羊。"); return row;
  };
  const spec = (kind, name, args, stream, streamID = id, occurredAt = now, extra = []) => ({
    kind, body: { [name]: args }, occurredAt, streams: [{ type: stream, id: streamID }, ...extra],
  });
  const care = (kind, name, args, stream, streamID = id, at = now, tuple = false) => spec(`care.${kind}`, name, tuple ? { _0: args } : args, stream, streamID, at);
  let commands = await additionalBusinessCommands(sheet,v,workspace,{id,date,decimal,listValues});
  if(commands)return commands;
  switch (sheet) {
    case "圈舍":
      requireValue(!rows("PenRecord").some((r) => normalized(r.name) === normalized(v["圈舍名称"])), "圈舍名称已存在。");
      commands = [spec("pen.create", "create", { name: v["圈舍名称"], note }, "pen")]; break;
    case "新建羊只": {
      requireValue(!rows("SheepRecord").some((r) => normalized(r.earTag) === normalized(v["耳号"])), "耳号已存在，请在原档案中修改。");
      requireValue(sex(v["性别"]), "性别请选择母羊、公羊或未知。");
      const enteredAt = date("入场日期"), birthAt = date("出生日期", true);
      requireValue(birthAt == null || birthAt <= enteredAt, "出生日期不能晚于入场日期。");
      commands = [spec("sheep.add", "add", { earTag: v["耳号"], breed: v["品种"], sex: sex(v["性别"]), penID: pen(v["圈舍"], true)?.id ?? null,
        occurredAt: enteredAt, birthAt, currentParity: sex(v["性别"]) === "ewe" ? integer(v["当前胎次"] || "0", "当前胎次") : null, note }, "sheep", id, enteredAt)]; break;
    }
    case "称重": commands = [spec("weight.record", "recordWeight", { sheepID: sheep(v["耳号"]).id, kilogramsText: decimal(v["体重kg"], "体重"), occurredAt: occurred(), note }, "weight", id, occurred())]; break;
    case "断奶": {
      const child = sheep(v["耳号"]), at = occurred();
      requireValue(!rows("WeaningRecord").some((r) => r.sheepID === child.id), "这只羊已有有效断奶记录，请核对后使用更正流程。");
      commands = [spec("weaning.record", "recordWeaning", { sheepID: child.id, weanWeightText: decimal(v["断奶重kg"], "断奶重"), occurredAt: at,
        birthAt: date("出生日期", true), birthWeightText: null, averageDailyGainText: null, damID: child.damID ?? null, litterSize: null, note }, "weaning", id, at),
      spec("transfer.record", "transferSheep", { sheepID: child.id, toPenID: pen(v["转入圈舍"]).id, occurredAt: at, note: "随断奶事件调舍" }, "transfer", await stableUUID(id, "weaning-transfer"), at, [{ type: "sheepLocation", id: child.id }])]; break;
    }
    case "转群": {
      const child = sheep(v["耳号"]), destination = pen(v["转入圈舍"]);
      requireValue(destination.isActive, "不能转入停用圈舍。");
      commands = [spec("transfer.record", "transferSheep", { sheepID: child.id, toPenID: destination.id, occurredAt: occurred(), note }, "transfer", id, occurred(), [{ type: "sheepLocation", id: child.id }])]; break;
    }
    case "离场": {
      const kind = removal(v["类型"]); requireValue(kind, "离场类型无效。");
      const batchID = await stableUUID(workspace.farm.id, `excel-v3:离场:${String(identity).toLowerCase()}:batch`);
      commands = await Promise.all(targets("羊只耳号列表").map(async (child) => {
        requireValue(child.statusRawValue === "active", `羊只 ${child.earTag} 已离场，不能重复离场。`);
        const recordID = await stableUUID(batchID, `member:${earKey(child.earTag)}`);
        return spec("removal.record", "removeSheep", { sheepID: child.id, kind, reason: v["原因"], amountText: null, occurredAt: occurred(), note,
          recordID, removalBatchID: batchID, batchTotalAmountText: kind === "sold" ? decimal(v["总售卖金额"], "总售卖金额") : null },
        "removal", recordID, occurred(), [{ type: "sheepLifecycle", id: child.id }]);
      })); break;
    }
    case "生产批次": commands = [spec("productionBatch.create", "createBatch", { name: v["批次名称"], purpose: v["生产目的"], startedAt: date("开始日期"), sheepIDs: targets("羊只耳号列表").map((r) => r.id), note }, "productionBatch", id, date("开始日期"))]; break;
    case "批次脱离": commands = [spec("batchMembership.leave", "leaveBatch", { batchID: find("ProductionBatchRecord", "name", v["批次名称"], "生产批次").id, sheepID: sheep(v["耳号"]).id, leftAt: date("脱离日期"), reason: v["原因"] }, "batchMembership", id, date("脱离日期"))]; break;
    case "饲料原料": commands = [spec("feedIngredient.add", "addIngredient", { name: v["原料名称"], unit: v["单位"], dryMatterText: decimal(v["干物质"], "干物质", false, true) }, "feedIngredient")]; break;
    case "饲料配方": commands = [spec("feedRecipe.create", "createRecipe", { name: v["配方名称"], note }, "feedRecipe")]; break;
    case "配方组成": commands = [spec("feedRecipe.member.add", "addRecipeComponent", { recipeID: recipe(v["配方名称"]).id, ingredientID: ingredient(v["原料名称"]).id, kilogramsText: decimal(v["用量kg"], "用量") }, "feedRecipeComponent")]; break;
    case "投喂": {
      requireValue(["限量投喂", "自由采食"].includes(v["方式"]), "投喂方式无效。");
      const lines = await Promise.all(listValues(v["投喂明细"]).map(async (value,i) => { const pair = value.split("|"); requireValue(pair.length === 2, "投喂明细请填写 原料|公斤;原料|公斤。"); return { id:await stableUUID(id,`feed-line-${i}`),ingredientBatchID:null,ingredientID: ingredient(pair[0]).id, kilogramsText: decimal(pair[1], "原料公斤数") }; }));
      requireValue(lines.length > 0, "至少填写一种原料。");
      commands = [spec("feed.recordLegacy", "recordLegacy", { penID: pen(v["圈舍"]).id, recipeID: recipe(v["配方名称"], true)?.id ?? null, mode: v["方式"] === "自由采食" ? "freeChoice" : "limited", occurredAt: occurred(), lines, note }, "feed", id, occurred())]; break;
    }
    case "健康目录": {
      requireValue(health(v["类型"]), "健康类型请选择治疗或疫苗。");
      const existing = rows("HealthCatalogItemRecord").find((r) => normalized(r.name) === normalized(v["名称"]));
      commands = [care("healthCatalog.upsert", "upsertHealthCatalog", { id: existing?.id ?? id, kindRawValue: health(v["类型"]), name: v["名称"], category: v["类别"] || "", unit: v["单位"], defaultDoseText: decimal(v["默认剂量"], "默认剂量", false, true), defaultRoute: v["给药途径"] || "", reminderIntervalDays: integer(v["复免间隔天"], "复免间隔天", 1, true), note, isActive: v["启用"] !== "否" }, "healthCatalogItem", existing?.id ?? id)]; break;
    }
    case "库存入库": {
      requireValue(health(v["类型"]), "库存类型请选择治疗或疫苗。");
      const match = rows("HealthCatalogItemRecord").find((r) => normalized(r.name) === normalized(v["目录名称"]));
      commands = [care("inventory.receive", "receiveInventory", { id, catalogName: v["目录名称"], catalogItemID: match?.id ?? null, kindRawValue: health(v["类型"]), batchNumber: v["批号"], supplier: v["供应商"] || "", unit: v["单位"], expiresAt: date("有效期", true), quantityText: decimal(v["数量"], "数量"), occurredAt: date("入库日期"), note }, "inventoryLot", id, date("入库日期"))]; break;
    }
    case "库存调整": commands = [care("inventory.adjust", "adjustInventory", { id, lotID: lot(v["目录名称"], v["批号"]).id, quantityDeltaText: decimal(v["调整数量"], "调整数量", true), occurredAt: occurred(), note }, "inventoryTransaction", id, occurred())]; break;
    case "健康记录": {
      let subjectIDs = nil(v["羊只耳号列表"]) ? targets("羊只耳号列表").map((r) => r.id) : [];
      const penID = pen(v["圈舍"], true)?.id ?? null;
      requireValue(subjectIDs.length || penID, "健康记录至少关联羊只或圈舍。");
      if(!subjectIDs.length)subjectIDs=rows("SheepRecord").filter(s=>presentAtTime(s,occurred(),models)&&penAtTime(s,occurred(),models)===penID).map(s=>s.id);
      requireValue(subjectIDs.length,"所选圈舍在发生时间没有在场羊只。");
      requireValue(health(v["类型"]), "健康类型请选择治疗或疫苗。");
      const inventory = nil(v["库存批号"]) ? lot(v["目录名称"] || v["名称"], v["库存批号"]) : null;
      const dose = decimal(v["每只剂量"], "每只剂量", false, !inventory);
      commands = [care("health.recordBatch", "recordHealth", { id, batchID: await stableUUID(id, "batch"), subjectIDs, penID,
        catalogItemID: catalog(v["目录名称"], true)?.id ?? null, kind: health(v["类型"]), itemName: v["名称"], occurredAt: occurred(), note,
        inventoryLotID: inventory?.id ?? null, dosePerSubjectText: dose, unit: v["单位"] || "", route: v["给药途径"] || "", reminderAt: date("提醒日期", true) }, "health", id, occurred(), true)]; break;
    }
    case "冻精供体": {
      const existing = rows("SemenDonorRecord").find((r) => nil(v["登记号"]) && normalized(r.registrationNumber) === normalized(v["登记号"]));
      commands = [care("semenDonor.upsert", "upsertSemenDonor", { id: existing?.id ?? id, name: v["供体名称"], registrationNumber: v["登记号"] || "", breed: v["品种"], linkedRamID: breedingRam(v["关联种公羊耳号"])?.id ?? null, note, status: v["状态"] === "停用" ? "inactive" : "active", expectedRevision: existing?.revision ?? 0 }, "semenDonor", existing?.id ?? id, now, true)]; break;
    }
    case "冻精入库": {
      commands = [spec("semen.add", "addSemen", { code: v["冻精编号"], breed: v["品种"], source: v["来源"] || "", batchNumber: v["批号"] || "", quantityText: decimal(v["数量"], "数量") }, "semen")];
      if (nil(v["供体登记号"])) commands.push(care("semen.setDonor", "setSemenDonor", { semenID: id, donorID: donor(v["供体登记号"]).id, expectedRevision: 1 }, "semen", id)); break;
    }
    case "冻精调整": commands = [care("semen.adjust", "adjustSemen", { id, semenID: semen(v["冻精编号"]).id, quantityDeltaText: decimal(v["调整数量"], "调整数量", true), occurredAt: occurred(), note }, "semenTransaction", id, occurred())]; break;
    case "繁殖记录": {
      const kind = repro(v["类型"]); requireValue(kind, "繁殖类型请选择配种、孕检或流产；产羔请使用产羔录入。");
      const sireID = breedingRam(v["种公羊耳号"])?.id ?? null, semenID = semen(v["冻精编号"], true)?.id ?? null;
      requireValue(kind === "breeding" ? Boolean(sireID) !== Boolean(semenID) : !sireID && !semenID, "配种时种公羊与冻精必须二选一；孕检或流产不能直接确认父本。");
      const subjects = await Promise.all(targets("母羊耳号列表").map(async (row) => { requireValue(row.sexRawValue === "ewe", `${row.earTag} 不是母羊。`); return { id: await stableUUID(id, earKey(row.earTag)), eweID: row.id, result: v["结果"] || "", relatedBreedingRecordID: null }; }));
      commands = [care("reproduction.recordBatch", "recordReproductionBatch", { id, kind, subjects, occurredAt: occurred(), sireID, semenID,
        semenUnitsPerEweText: decimal(v["每只冻精数量"], "每只冻精数量", false, !semenID), note, reminderAt: date("提醒日期", true) }, "careBatch", id, occurred(), true)]; break;
    }
    case "产羔": {
      const ewe = sheep(v["母羊耳号"]); requireValue(ewe.sexRawValue === "ewe", "产羔对象必须是母羊。");
      const sireID = breedingRam(v["种公羊耳号"])?.id ?? null, semenID = semen(v["冻精编号"], true)?.id ?? null;
      requireValue(!sireID || !semenID, "种公羊与冻精不能同时填写。");
      const offspring = await Promise.all(listValues(v["产羔明细"]).map(async (text, i) => {
        const [tag, s, weight, weightDate, create, stillborn, ...extra] = text.split("|").map((v) => v.trim());
        requireValue(!extra.length && tag && sex(s) && ["是", "否"].includes(create) && ["是", "否"].includes(stillborn), "产羔明细请填写 耳号|性别|体重|称重日期|建档|死胎。");
        requireValue(!(create === "是" && stillborn === "是"), "死胎不能建立在场羊只档案。");
        requireValue(create !== "是" || !rows("SheepRecord").some((r) => normalized(r.earTag) === normalized(tag)), `羔羊耳号 ${tag} 已存在。`);
        return { id: await stableUUID(id, `lamb-detail-${i}`), sheepID: await stableUUID(id, `lamb-sheep-${i}`), earTag: tag, breed: null, sex: sex(s),
          birthWeightText: decimal(weight, "羔羊体重", false, true) || "", weightOccurredAt: parseBusinessDate(weightDate, timezone, true), createSheepRecord: create === "是", isStillborn: stillborn === "是" };
      }));
      requireValue(offspring.length > 0 && new Set(offspring.filter((l) => l.createSheepRecord).map((l) => normalized(l.earTag))).size === offspring.filter((l) => l.createSheepRecord).length, "产羔明细为空或有重复耳号。");
      const prior=rows("ReproductionRecord").filter(r=>r.eweID===ewe.id&&r.parity>=0&&((r.kindRawValue==="lambing"&&r.occurredAt<occurred())||(r.kindRawValue==="parityBaseline"&&r.occurredAt<=occurred()))).sort((a,b)=>b.occurredAt-a.occurredAt||b.updatedAt-a.updatedAt||b.createdAt-a.createdAt)[0];
      const parity=(prior?.parity??0)+1;
      commands = [care("lambing.record", "recordLambing", { id, eweID: ewe.id, occurredAt: occurred(), sireID, semenID, relatedBreedingRecordID: null,
        parity, birthDeadCount: offspring.filter((l) => l.isStillborn).length, offspring, penID: pen(v["圈舍"], true)?.id ?? null, note }, "reproduction", id, occurred(), true)]; break;
    }
    case "系谱关系": {
      const child = sheep(v["羊只耳号"]), source = v["父本来源"];
      requireValue(["未知", "种公羊", "冻精供体"].includes(source), "父本来源无效。");
      requireValue(source === "未知" ? !nil(v["种公羊耳号"]) && !nil(v["供体登记号"]) : source === "种公羊" ? nil(v["种公羊耳号"]) && !nil(v["供体登记号"]) : nil(v["供体登记号"]) && !nil(v["种公羊耳号"]), "父本来源与填写的父本资料不一致。");
      commands = [care("sheepPedigree.update", "updateSheepPedigree", { id, sheepID: child.id, damID: sheep(v["母本耳号"], true)?.id ?? null,
        sireID: source === "种公羊" ? breedingRam(v["种公羊耳号"]).id : null, semenDonorID: source === "冻精供体" ? donor(v["供体登记号"]).id : null,
        reason: v["修改原因"], expectedRevision: child.revision }, "sheep", child.id, now, true)]; break;
    }
    case "配种方案": {
      const steps = await Promise.all(listValues(v["步骤"]).map(async (text,i) => { const [offset, action, ...extra] = text.split("|"); requireValue(!extra.length && action?.trim(), "步骤请填写 天数|操作;天数|操作。"); return { id:await stableUUID(id,`step-${i}`),dayOffset: integer(offset, "步骤天数"), action: action.trim() }; }));
      commands = [spec("breedingProgram.create", "createBreedingProgram", { name: v["方案名称"], createdAt: date("创建日期"), steps }, "breedingProgram", id, date("创建日期"))]; break;
    }
    case "备注": {
      const sheepID = sheep(v["耳号"], true)?.id ?? null, penID = pen(v["圈舍"], true)?.id ?? null;
      requireValue(sheepID || penID, "备注至少关联羊只或圈舍。");
      requireValue(nil(v["内容"]), "备注内容不能为空。");
      commands = [spec("note.add", "addNote", { sheepID, penID, text: v["内容"], occurredAt: occurred() }, "note", id, occurred())]; break;
    }
    case "提醒规则": {
      const existing = rows("FarmCareRuleRecord")[0], ruleID = existing?.id ?? id;
      const base = { id: ruleID, pregnancyCheckDays: integer(v["孕检间隔天"], "孕检间隔天", 1), gestationDays: integer(v["妊娠周期天"], "妊娠周期天", 1) };
      if (nil(v["断奶日龄"])) {
        const match = /^(\d\d?):(\d\d)$/.exec(v["每日汇总时间"] || ""); requireValue(match && +match[1] < 24 && +match[2] < 60, "每日汇总时间请使用 HH:mm。");
        commands = [care("operationalAlertRules.update", "updateOperationalAlertRules", { ...base, weaningAgeDays: integer(v["断奶日龄"], "断奶日龄", 1),
          warningLeadDays: integer(v["提前预警天数"] || "0", "提前预警天数"), digestEnabled: true, digestMinuteOfDay: +match[1] * 60 + +match[2] }, "careRule", ruleID, now, true)];
      } else commands = [care("careRules.update", "updateRules", base, "careRule", ruleID)]; break;
    }
    default: throw new Error(`尚不支持业务类型“${sheet}”。`);
  }
  requireValue(commands.length <= 25, "一次最多提交 25 只羊的关联操作，请拆分批次。");
  for (const command of commands) requireValue(Number.isFinite(command.occurredAt), "业务发生日期无效。");
  validateBusinessSpecifications(commands,workspace);
  return commands;
}
