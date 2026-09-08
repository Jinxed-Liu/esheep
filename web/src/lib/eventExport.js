import contract from "./appEventExportContract.json" with { type: "json" };
export { contract as eventExportContract };
const dateFormatters=new Map();
export function farmDateText(value, timeZone, includeTime = true) {
  if (value == null || value === "") return "";
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) throw new Error("记录日期无效，无法导出。");
  const cacheKey=`${timeZone}:${includeTime}`;
  if(!dateFormatters.has(cacheKey))dateFormatters.set(cacheKey,new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit",
    ...(includeTime ? { hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" } : {}) }));
  const parts=Object.fromEntries(dateFormatters.get(cacheKey).formatToParts(date).map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}${includeTime ? ` ${parts.hour}:${parts.minute}:${parts.second}` : ""}`;
}
export function matchingEvents(events, { scope = "all", start = "", end = "", query = "", timeZone = "Asia/Shanghai" } = {}) {
  const bounds = [start, end].filter(Boolean).sort();
  return events.filter((event) => {
    if (event.status !== "synced") return false;
    if (scope !== "all" && event.scope !== scope) return false;
    const day = start||end?farmDateText(event.at, timeZone, false):"";
    if (start && end ? day < bounds[0] || day > bounds[1] : start ? day < start : end ? day > end : false) return false;
    return !query || [event.object, event.label, event.detail, event.note, ...(event.fields ?? []).map((f) => f.value)].join(" ").toLowerCase().includes(query.trim().toLowerCase());
  }).sort((a, b) => new Date(b.at) - new Date(a.at) || new Date(b.recordedAt) - new Date(a.recordedAt) || b.id.toLowerCase().localeCompare(a.id.toLowerCase()));
}
export function exportEventsCSV(events, options = {}) {
  const records = matchingEvents(events, options);
  const fields = [...new Set(records.flatMap((event) => (event.fields ?? []).map((field) => field.label)))];
  const headers = [...contract.fixedColumns, ...fields, ...contract.trailingColumns];
  const rows = records.map((event) => {
    const values = new Map();
    for (const field of event.fields ?? []) if (!values.has(field.label)) values.set(field.label, field.value);
    return [farmDateText(event.at, options.timeZone || "Asia/Shanghai"), farmDateText(event.recordedAt, options.timeZone || "Asia/Shanghai"),
      contract.categories.find((category) => category.id === event.category)?.name ?? event.category,
      event.label, event.object, event.detail, ...fields.map((name) => values.get(name) ?? ""), event.note ?? "", event.id.toLowerCase()];
  });
  // Match the native exporter: every field quoted, embedded quotes doubled,
  // CRLF rows and a UTF-8 BOM. Never convert ear tags into numeric cells.
  return "\uFEFF" + [headers, ...rows].map((row) => row.map((value) => `"${String(value ?? "").replaceAll('"', '""')}"`).join(",")).join("\r\n") + "\r\n";
}
export function eventExportFileName(farmName, { scope = "all", start = "", end = "", timeZone = "Asia/Shanghai" } = {}) {
  const safeName = farmName.replace(/[\/\\:*?"<>|]/g, "-").trim() || "牧场";
  const date = farmDateText(Date.now(), timeZone, false).replaceAll("-", "");
  const bounds = [start, end].filter(Boolean).sort().map((value) => value.replaceAll("-", ""));
  const range = bounds.length ? `${bounds[0]}-${bounds.at(-1)}` : "全部时间";
  return `${contract.scopes.find((item) => item.id === scope)?.name ?? "全部记录"}_${safeName}_${range}_${date}.csv`;
}
export function downloadFile(content, filename, type = "text/csv;charset=utf-8") {
  const url = URL.createObjectURL(new Blob([content], { type }));
  const link = document.createElement("a"); link.href = url; link.download = filename; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
