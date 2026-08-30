#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const repositoryRoot = path.resolve(import.meta.dirname, "..");

const pages = [
  {
    source: "release/legal/privacy-policy.zh-Hans.md",
    destination: "release/site-template/zh-cn/privacy/index.html",
    title: "eSheep+ 隐私政策",
    language: "zh-CN",
    locale: "zh-cn",
  },
  {
    source: "release/legal/terms.zh-Hans.md",
    destination: "release/site-template/zh-cn/terms/index.html",
    title: "eSheep+ 服务条款",
    language: "zh-CN",
    locale: "zh-cn",
  },
  {
    source: "release/legal/ai-and-cross-border.zh-Hans.md",
    destination: "release/site-template/zh-cn/ai-privacy/index.html",
    title: "eSheep+ AI 与境外提供个人信息告知",
    language: "zh-CN",
    locale: "zh-cn",
  },
  {
    source: "release/legal/privacy-policy.en.md",
    destination: "release/site-template/en/privacy/index.html",
    title: "eSheep+ Privacy Policy",
    language: "en",
    locale: "en",
  },
  {
    source: "release/legal/terms.en.md",
    destination: "release/site-template/en/terms/index.html",
    title: "eSheep+ Terms of Service",
    language: "en",
    locale: "en",
  },
  {
    source: "release/legal/ai-and-cross-border.en.md",
    destination: "release/site-template/en/ai-privacy/index.html",
    title: "eSheep+ AI and International Transfer Notice",
    language: "en",
    locale: "en",
  },
];

function escapeHTML(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function renderInline(value) {
  return escapeHTML(value)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
}

function isTableSeparator(line) {
  return /^\s*\|?(?:\s*:?-{3,}:?\s*\|)+\s*:?-{3,}:?\s*\|?\s*$/.test(line);
}

function tableCells(line) {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

function renderMarkdown(markdown) {
  const lines = markdown.replaceAll("\r\n", "\n").split("\n");
  const output = [];
  let paragraph = [];
  let listType = null;

  const flushParagraph = () => {
    if (paragraph.length === 0) return;
    output.push(`<p>${renderInline(paragraph.join(" ").replace(/\s{2,}/g, " "))}</p>`);
    paragraph = [];
  };

  const closeList = () => {
    if (listType === null) return;
    output.push(`</${listType}>`);
    listType = null;
  };

  for (let index = 0; index < lines.length; index += 1) {
    const rawLine = lines[index];
    const line = rawLine.trim();
    const nextLine = lines[index + 1]?.trim() ?? "";

    if (line === "") {
      flushParagraph();
      closeList();
      continue;
    }

    const heading = /^(#{1,6})\s+(.+)$/.exec(line);
    if (heading) {
      flushParagraph();
      closeList();
      const level = heading[1].length;
      output.push(`<h${level}>${renderInline(heading[2])}</h${level}>`);
      continue;
    }

    if (line.includes("|") && isTableSeparator(nextLine)) {
      flushParagraph();
      closeList();
      const headers = tableCells(line);
      index += 2;
      const rows = [];
      while (index < lines.length && lines[index].trim().includes("|")) {
        rows.push(tableCells(lines[index]));
        index += 1;
      }
      index -= 1;
      output.push("<div class=\"table-scroll\"><table><thead><tr>");
      headers.forEach((cell) => output.push(`<th>${renderInline(cell)}</th>`));
      output.push("</tr></thead><tbody>");
      rows.forEach((row) => {
        output.push("<tr>");
        headers.forEach((_, cellIndex) => {
          output.push(`<td>${renderInline(row[cellIndex] ?? "")}</td>`);
        });
        output.push("</tr>");
      });
      output.push("</tbody></table></div>");
      continue;
    }

    const unorderedItem = /^[-*]\s+(.+)$/.exec(line);
    const orderedItem = /^\d+\.\s+(.+)$/.exec(line);
    if (unorderedItem || orderedItem) {
      flushParagraph();
      const requestedList = unorderedItem ? "ul" : "ol";
      if (listType !== requestedList) {
        closeList();
        listType = requestedList;
        output.push(`<${listType}>`);
      }
      output.push(`<li>${renderInline((unorderedItem ?? orderedItem)[1])}</li>`);
      continue;
    }

    closeList();
    paragraph.push(line.replace(/\s{2}$/, ""));
  }

  flushParagraph();
  closeList();
  return output.join("\n");
}

function navigation(locale, route) {
  if (locale === "zh-cn") {
    return `
      <nav aria-label="法律与支持">
        <a href="../privacy/">隐私政策</a>
        <a href="../terms/">服务条款</a>
        <a href="../ai-privacy/">AI 与境外处理</a>
        <a href="../account-deletion/">删除账号</a>
        <a href="../support/">支持</a>
        <a href="../../en/${route}/" hreflang="en">English</a>
      </nav>`;
  }
  return `
      <nav aria-label="Legal and support">
        <a href="../privacy/">Privacy</a>
        <a href="../terms/">Terms</a>
        <a href="../ai-privacy/">AI &amp; transfers</a>
        <a href="../account-deletion/">Delete account</a>
        <a href="../support/">Support</a>
        <a href="../../zh-cn/${route}/" hreflang="zh-CN">简体中文</a>
      </nav>`;
}

for (const page of pages) {
  const sourcePath = path.join(repositoryRoot, page.source);
  const destinationPath = path.join(repositoryRoot, page.destination);
  const route = path.basename(path.dirname(destinationPath));
  const body = renderMarkdown(fs.readFileSync(sourcePath, "utf8"));
  const html = `<!doctype html>
<html lang="${page.language}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="index,follow">
  <title>${escapeHTML(page.title)}</title>
  <link rel="icon" href="../../assets/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="../../assets/site.css">
</head>
<body>
  <header>${navigation(page.locale, route)}</header>
  <main>${body}</main>
  <footer>eSheep+ · ${page.locale === "zh-cn" ? "法律文本版本 2026.09.01" : "Legal version 2026.09.01"}</footer>
</body>
</html>
`;
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true });
  fs.writeFileSync(destinationPath, html, "utf8");
}

process.stdout.write(`Rendered ${pages.length} legal pages.\n`);
