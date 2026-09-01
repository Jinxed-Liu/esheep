import { unzipSync } from "fflate";

const decoder = new TextDecoder();

function parseXML(bytes, label) {
  const document = new DOMParser().parseFromString(decoder.decode(bytes), "application/xml");
  if (document.querySelector("parsererror")) throw new Error(`${label} 不是有效的 Excel XML。`);
  return document;
}

function cellColumn(reference) {
  return [...String(reference).match(/^[A-Z]+/)?.[0] ?? ""].reduce((value, character) => value * 26 + character.charCodeAt(0) - 64, 0) - 1;
}

function workbookSheets(files) {
  const workbook = parseXML(files["xl/workbook.xml"], "工作簿");
  const relationships = parseXML(files["xl/_rels/workbook.xml.rels"], "工作簿关系");
  const targets = new Map([...relationships.querySelectorAll("Relationship")].map((item) => [item.getAttribute("Id"), item.getAttribute("Target")]));
  return [...workbook.querySelectorAll("sheet")].map((sheet) => {
    const id = sheet.getAttribute("r:id") ?? sheet.getAttributeNS("http://schemas.openxmlformats.org/officeDocument/2006/relationships", "id");
    const target = targets.get(id)?.replace(/^\//, "").replace(/^xl\//, "") ?? "";
    return { name: sheet.getAttribute("name"), path: `xl/${target}`.replace("xl/../", "") };
  });
}

function sharedStrings(files) {
  if (!files["xl/sharedStrings.xml"]) return [];
  const document = parseXML(files["xl/sharedStrings.xml"], "共享文本");
  return [...document.querySelectorAll("si")].map((item) => [...item.querySelectorAll("t")].map((node) => node.textContent ?? "").join(""));
}

function readRows(bytes, shared) {
  const document = parseXML(bytes, "工作表");
  return [...document.querySelectorAll("sheetData > row")].map((row) => {
    const values = [];
    for (const cell of row.querySelectorAll("c")) {
      const column = cellColumn(cell.getAttribute("r"));
      while (values.length <= column) values.push("");
      const type = cell.getAttribute("t");
      const raw = type === "inlineStr"
        ? [...cell.querySelectorAll("is t")].map((node) => node.textContent ?? "").join("")
        : cell.querySelector("v")?.textContent ?? "";
      values[column] = type === "s" ? shared[Number(raw)] ?? "" : raw;
    }
    return values;
  });
}

export async function inspectExcelWorkbook(file, contractURL) {
  if (!file?.name?.toLowerCase().endsWith(".xlsx")) throw new Error("请选择 .xlsx 工作簿。");
  if (file.size > 25 * 1024 * 1024) throw new Error("工作簿超过 25 MB，请拆分后再导入。");
  const [buffer, response] = await Promise.all([file.arrayBuffer(), fetch(contractURL)]);
  if (!response.ok) throw new Error("无法读取 App Excel 模板契约。");
  const contract = await response.json();
  let files;
  try {
    files = unzipSync(new Uint8Array(buffer));
  } catch {
    throw new Error("无法解压工作簿，请确认文件没有损坏或加密。");
  }
  if (!files["xl/workbook.xml"] || !files["xl/_rels/workbook.xml.rels"]) throw new Error("文件不是有效的 Excel 工作簿。");
  const shared = sharedStrings(files);
  const sheets = workbookSheets(files).map((sheet) => ({ ...sheet, rows: files[sheet.path] ? readRows(files[sheet.path], shared) : [] }));
  const issues = [];
  const summaries = [];
  const importKeys = new Set();
  for (const schema of contract.schemas) {
    const sheet = sheets.find((item) => item.name === schema.name);
    if (!sheet) continue;
    const header = sheet.rows[0]?.map((value) => String(value).trim()) ?? [];
    for (const column of schema.columns) if (!header.includes(column)) issues.push(`${schema.name}：缺少模板字段“${column}”`);
    const headerIndex = new Map(header.map((name, index) => [name, index]));
    let rowCount = 0;
    for (const [offset, row] of sheet.rows.slice(1).entries()) {
      const values = row.map((value) => String(value).trim());
      if (values.every((value) => !value) || values[0]?.startsWith("示例")) continue;
      rowCount += 1;
      for (const required of schema.required) if (!values[headerIndex.get(required)]?.trim()) issues.push(`${schema.name} 第 ${offset + 2} 行：“${required}”不能为空`);
      const importKey = values[headerIndex.get("导入键")]?.toLowerCase();
      if (importKey && importKeys.has(importKey)) issues.push(`${schema.name} 第 ${offset + 2} 行：导入键“${importKey}”与文件内其他行重复`);
      if (importKey) importKeys.add(importKey);
    }
    if (rowCount) summaries.push({ name: schema.name, rowCount });
  }
  const supportedNames = new Set(["填写说明", ...contract.schemas.map((schema) => schema.name)]);
  const ignoredSheets = sheets.map((sheet) => sheet.name).filter((name) => !supportedNames.has(name));
  if (!summaries.length && !issues.length) issues.push("没有找到可导入的数据行；请删除或覆盖模板中的示例行。");
  return { version: contract.version, fileName: file.name, summaries, issues, ignoredSheets };
}
