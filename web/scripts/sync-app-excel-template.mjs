import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const appContractPath = path.resolve(webRoot, "../eSheepNext/Services/FarmExcelImport.swift");
const source = readFileSync(appContractPath, "utf8");

const version = Number(source.match(/static let templateVersion = (\d+)/)?.[1]);
if (!Number.isInteger(version)) throw new Error("无法从 App 读取 Excel 模板版本。");

function swiftStrings(sourceText) {
  return [...sourceText.matchAll(/"((?:\\.|[^"\\])*)"/g)].map((match) => match[1]
    .replaceAll("\\\"", "\"")
    .replaceAll("\\n", "\n")
    .replaceAll("\\\\", "\\")
    .replaceAll("\\(templateVersion)", String(version)));
}

const schemaPattern = /\.init\(name: "([^"]+)", capability: \.[^,]+, columns: \[([^\]]*)\], required: \[([^\]]*)\], example: \[([^\]]*)\]\)/g;
const schemas = [...source.matchAll(schemaPattern)].map((match) => ({
  name: match[1],
  columns: swiftStrings(match[2]),
  required: swiftStrings(match[3]),
  example: swiftStrings(match[4]),
}));
if (schemas.length < 20) throw new Error(`App Excel 模板解析不完整：仅识别 ${schemas.length} 个工作表。`);

const instructionBlock = source.match(/let instructions = XLSXSheet\(name: "填写说明", rows: \[([\s\S]*?)\n\s*\]\)\n\s*return try XLSXCodec/)?.[1];
if (!instructionBlock) throw new Error("无法从 App 读取填写说明。");
const instructionRows = [...instructionBlock.matchAll(/\[([^\[\]]*)\]/g)].map((match) => swiftStrings(match[1]));
instructionRows[0] = ["eSheep+ 全功能录入模板", `版本 ${version}`];

function xmlEscape(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
}

function columnName(number) {
  let value = number;
  let result = "";
  while (value > 0) {
    value -= 1;
    result = String.fromCharCode(65 + (value % 26)) + result;
    value = Math.floor(value / 26);
  }
  return result;
}

const crcTable = Array.from({ length: 256 }, (_, value) => {
  let crc = value;
  for (let bit = 0; bit < 8; bit += 1) crc = (crc & 1) ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  return crc >>> 0;
});

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function uint16(value) {
  const buffer = Buffer.alloc(2);
  buffer.writeUInt16LE(value);
  return buffer;
}

function uint32(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value >>> 0);
  return buffer;
}

function zip(entries) {
  const localParts = [];
  const centralParts = [];
  let offset = 0;
  for (const [name, content] of entries) {
    const nameBuffer = Buffer.from(name);
    const data = Buffer.isBuffer(content) ? content : Buffer.from(content);
    const crc = crc32(data);
    const local = Buffer.concat([
      uint32(0x04034b50), uint16(20), uint16(0), uint16(0), uint16(0), uint16(0),
      uint32(crc), uint32(data.length), uint32(data.length), uint16(nameBuffer.length), uint16(0), nameBuffer, data,
    ]);
    localParts.push(local);
    centralParts.push(Buffer.concat([
      uint32(0x02014b50), uint16(20), uint16(20), uint16(0), uint16(0), uint16(0), uint16(0),
      uint32(crc), uint32(data.length), uint32(data.length), uint16(nameBuffer.length), uint16(0), uint16(0),
      uint16(0), uint16(0), uint32(0), uint32(offset), nameBuffer,
    ]));
    offset += local.length;
  }
  const central = Buffer.concat(centralParts);
  return Buffer.concat([
    ...localParts,
    central,
    uint32(0x06054b50), uint16(0), uint16(0), uint16(entries.length), uint16(entries.length),
    uint32(central.length), uint32(offset), uint16(0),
  ]);
}

const sheets = [
  { name: "填写说明", rows: instructionRows },
  ...schemas.map((schema) => ({ name: schema.name, rows: [schema.columns, schema.example] })),
];
const overrides = sheets.map((_, index) => `<Override PartName="/xl/worksheets/sheet${index + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("");
const workbookSheets = sheets.map((sheet, index) => `<sheet name="${xmlEscape(sheet.name)}" sheetId="${index + 1}" r:id="rId${index + 1}"/>`).join("");
const relationships = sheets.map((_, index) => `<Relationship Id="rId${index + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${index + 1}.xml"/>`).join("");
const styles = `<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="3"><font><sz val="11"/><name val="Aptos"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Aptos"/></font><font><i/><color rgb="FF666666"/><sz val="11"/><name val="Aptos"/></font></fonts><fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF2E7D5B"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF2F4F3"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="0" fontId="2" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>`;
const entries = [
  ["[Content_Types].xml", `<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>${overrides}</Types>`],
  ["_rels/.rels", `<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`],
  ["xl/workbook.xml", `<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${workbookSheets}</sheets></workbook>`],
  ["xl/_rels/workbook.xml.rels", `<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${relationships}<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`],
  ["xl/styles.xml", styles],
];
for (const [sheetIndex, sheet] of sheets.entries()) {
  const rows = sheet.rows.map((row, rowIndex) => {
    const cells = row.map((value, columnIndex) => {
      const style = rowIndex === 0 ? ' s="1"' : String(value).startsWith("示例") ? ' s="2"' : "";
      return `<c r="${columnName(columnIndex + 1)}${rowIndex + 1}"${style} t="inlineStr"><is><t xml:space="preserve">${xmlEscape(value)}</t></is></c>`;
    }).join("");
    return `<row r="${rowIndex + 1}">${cells}</row>`;
  }).join("");
  const maxColumns = Math.max(1, ...sheet.rows.map((row) => row.length));
  const columns = Array.from({ length: maxColumns }, (_, index) => `<col min="${index + 1}" max="${index + 1}" width="18" customWidth="1"/>`).join("");
  entries.push([`xl/worksheets/sheet${sheetIndex + 1}.xml`, `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols>${columns}</cols><sheetData>${rows}</sheetData><autoFilter ref="A1:${columnName(maxColumns)}${sheet.rows.length}"/></worksheet>`]);
}

const outputDirectory = path.join(webRoot, "public", "downloads");
mkdirSync(outputDirectory, { recursive: true });
const fileBase = `eSheepPlus_全功能录入模板_v${version}`;
writeFileSync(path.join(outputDirectory, `${fileBase}.xlsx`), zip(entries));
writeFileSync(path.join(outputDirectory, `${fileBase}.json`), `${JSON.stringify({ version, fileName: `${fileBase}.xlsx`, schemas }, null, 2)}\n`);
console.log(`已从 App 契约同步 Excel v${version}：${schemas.length} 个业务工作表。`);
