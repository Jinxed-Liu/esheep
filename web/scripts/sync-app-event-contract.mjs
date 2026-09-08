import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const source = read("../../eSheepNext/Services/FarmEventCSVExport.swift");
const history = read("../../eSheepNext/Features/Workspace/FarmEventHistoryView.swift");
const strings = (value) => [...value.matchAll(/"([^"\\]*)"/g)].map((match) => match[1]);
const fixedColumns = strings(source.match(/static let fixedColumnTitles = \[([^\]]+)\]/)[1]);
const names = (text) => [...text.matchAll(/case \.(\w+): "([^"]+)"/g)].map((match) => ({ id: match[1], name: match[2] }));
const scopes = names(source.split("var displayName: String")[1].split("var symbol:")[0]);
const categories = names(history.split("var displayName: String")[1].split("var symbol:")[0]);
const fieldLabels = [...new Set([...history.split("struct FarmEventHistoryView:")[0].matchAll(/label: "([^"]+)"/g)].map((match) => match[1]))];
if (scopes.length !== 13 || fixedColumns.length !== 6 || fieldLabels.length < 35) throw new Error("App 事件导出契约解析失败，停止构建。");
const contract = { source: "FarmEventCSVExport.swift / FarmEventHistoryView.swift", format: "csv", encoding: "UTF-8-BOM",
  fixedColumns, trailingColumns: ["备注", "记录ID"], scopes, categories, fieldLabels,
  dateTimeFormat: "yyyy-MM-dd HH:mm:ss", sort: ["occurredAt:desc", "recordedAt:desc", "id:desc"] };
writeFileSync(fileURLToPath(new URL("../src/lib/appEventExportContract.json", import.meta.url)), JSON.stringify(contract, null, 2) + "\n");
console.log(`已同步 App 事件导出契约：${scopes.length} 类、${fieldLabels.length} 个业务字段。`);
