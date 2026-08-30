#!/usr/bin/env python3
"""Build the printable eSheep+ 3.1 privacy compliance workbook."""

from __future__ import annotations

import html
import math
import re
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    KeepTogether,
    LongTable,
    NextPageTemplate,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)
from reportlab.platypus.tableofcontents import TableOfContents


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_PATH = (
    REPOSITORY_ROOT
    / "output/pdf/eSheepPlus-3.1-个人信息保护合规工作包-2026-08-27.pdf"
)

BRAND = colors.HexColor("#176B3A")
BRAND_DARK = colors.HexColor("#104B2A")
BRAND_LIGHT = colors.HexColor("#EAF4ED")
INK = colors.HexColor("#182019")
MUTED = colors.HexColor("#5D695F")
LINE = colors.HexColor("#DCE4DD")
WARNING = colors.HexColor("#9A5B00")
WARNING_LIGHT = colors.HexColor("#FFF4DD")
RED = colors.HexColor("#A83232")
RED_LIGHT = colors.HexColor("#FCECEC")

PLACEHOLDERS = {
    "{{LEGAL_ENTITY}}": "[待填写: 个人信息处理者法定全称]",
    "{{REGISTERED_ADDRESS}}": "[待填写: 注册地址]",
    "{{PRIVACY_OWNER}}": "[待填写: 个人信息保护负责人]",
    "{{PRIVACY_EMAIL}}": "[待填写: 隐私权利请求邮箱]",
    "{{DOMAIN}}": "[待填写: 正式 HTTPS 域名]",
    "{{SUPABASE_REGION_COUNTRY}}": "[待填写: Production Supabase 实际国家或地区]",
    "{{SMTP_PROVIDER}}": "[待填写: Production SMTP 服务商]",
    "{{SMTP_REGION_COUNTRY}}": "[待填写: SMTP 实际国家或地区]",
    "{{SMTP_PRIVACY_URL}}": "[待填写: SMTP 隐私政策或权利渠道]",
    "{{SMTP_RETENTION}}": "[待填写: SMTP 实际保存期限]",
    "{{MIMO_API_REGION_COUNTRY}}": "[待填写: MiMo API 内容实际处理或存储地域]",
}

DASH_TRANSLATION = str.maketrans(
    {
        "\u2010": "-",
        "\u2011": "-",
        "\u2012": "-",
        "\u2013": "-",
        "\u2014": "-",
        "\u2212": "-",
    }
)

SOURCE_DOCUMENTS = [
    ("附录 A - 个人信息与权限清单", "docs/compliance/个人信息与权限清单.md", "landscape"),
    ("附录 B - 第三方、受托处理与出境清单", "docs/compliance/第三方与出境清单.md", "landscape"),
    ("附录 C - 个人信息保护影响评估", "docs/compliance/个人信息保护影响评估.md", "portrait"),
    ("附录 D - 官方 24 项合规审计自查", "docs/compliance/小型个人信息处理者合规审计自查表.md", "landscape"),
    ("附录 E - 个人信息保护内部管理制度", "docs/compliance/个人信息保护内部管理制度.md", "portrait"),
    ("附录 F - 个人信息安全事件应急预案", "docs/compliance/个人信息安全事件应急预案.md", "portrait"),
    ("附录 G - 个人信息权利请求处理记录模板", "docs/compliance/个人信息权利请求处理记录模板.md", "landscape"),
    ("附录 H - 培训与演练记录模板", "docs/compliance/个人信息保护培训与演练记录模板.md", "landscape"),
    ("附录 I - App Store 隐私问卷", "release/app-store/privacy/privacy-questionnaire.zh-Hans.md", "landscape"),
    ("附录 J - 中文隐私政策", "release/legal/privacy-policy.zh-Hans.md", "portrait"),
    ("附录 K - 中文服务条款", "release/legal/terms.zh-Hans.md", "portrait"),
    ("附录 L - 中文 AI 与境外提供告知", "release/legal/ai-and-cross-border.zh-Hans.md", "portrait"),
    ("附录 M - English Privacy Policy", "release/legal/privacy-policy.en.md", "portrait"),
    ("附录 N - English Terms of Service", "release/legal/terms.en.md", "portrait"),
    ("附录 O - English AI and International Transfer Notice", "release/legal/ai-and-cross-border.en.md", "portrait"),
]


def normalize_text(value: str) -> str:
    value = value.translate(DASH_TRANSLATION)
    for token, replacement in PLACEHOLDERS.items():
        value = value.replace(token, replacement)
    return value


def inline_markup(value: str) -> str:
    value = normalize_text(value)
    escaped = html.escape(value, quote=True)
    escaped = re.sub(
        r"\[([^\]]+)\]\((https?://[^)]+)\)",
        r'<link href="\2" color="#176B3A"><u>\1</u></link>',
        escaped,
    )
    escaped = re.sub(r"`([^`]+)`", r'<font color="#355D43">\1</font>', escaped)
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", escaped)
    return escaped


def is_table_separator(line: str) -> bool:
    return bool(
        re.match(
            r"^\s*\|?(?:\s*:?-{3,}:?\s*\|)+\s*:?-{3,}:?\s*\|?\s*$",
            line,
        )
    )


def table_cells(line: str) -> list[str]:
    stripped = line.strip().strip("|")
    return [cell.strip() for cell in stripped.split("|")]


def compute_column_widths(rows: list[list[str]], available_width: float) -> list[float]:
    column_count = max(len(row) for row in rows)
    weights: list[float] = []
    for index in range(column_count):
        lengths = [len(row[index]) if index < len(row) else 0 for row in rows]
        maximum = max(lengths, default=8)
        weight = max(0.72, min(2.6, math.sqrt(maximum + 4) / 4.0))
        if index == 0:
            weight = min(weight, 1.15)
        weights.append(weight)
    total = sum(weights)
    return [available_width * weight / total for weight in weights]


def make_table(
    rows: list[list[str]],
    available_width: float,
    styles: dict[str, ParagraphStyle],
) -> LongTable:
    column_count = max(len(row) for row in rows)
    font_size = 6.4 if column_count >= 6 else 7.2 if column_count >= 4 else 8.2
    leading = font_size + 2.0
    cell_style = ParagraphStyle(
        f"TableCell{column_count}",
        parent=styles["Body"],
        fontSize=font_size,
        leading=leading,
        textColor=INK,
        spaceAfter=0,
    )
    header_style = ParagraphStyle(
        f"TableHeader{column_count}",
        parent=cell_style,
        fontName="HeitiMedium",
        textColor=colors.white,
    )
    rendered: list[list[Paragraph]] = []
    for row_index, row in enumerate(rows):
        padded = row + [""] * (column_count - len(row))
        style = header_style if row_index == 0 else cell_style
        rendered.append([Paragraph(inline_markup(cell), style) for cell in padded])

    table = LongTable(
        rendered,
        colWidths=compute_column_widths(rows, available_width),
        repeatRows=1,
        splitByRow=1,
        hAlign="LEFT",
    )
    commands = [
        ("BACKGROUND", (0, 0), (-1, 0), BRAND_DARK),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("GRID", (0, 0), (-1, -1), 0.35, LINE),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]
    for row_index in range(1, len(rows)):
        if row_index % 2 == 0:
            commands.append(("BACKGROUND", (0, row_index), (-1, row_index), colors.HexColor("#F7FAF7")))
    table.setStyle(TableStyle(commands))
    return table


def markdown_story(
    markdown: str,
    available_width: float,
    styles: dict[str, ParagraphStyle],
) -> list:
    markdown = normalize_text(markdown).replace("\r\n", "\n")
    if re.search(r"\{\{[A-Z0-9_]+\}\}", markdown):
        raise ValueError("Unmapped publication placeholder remains in PDF source")

    lines = markdown.splitlines()
    story: list = []
    paragraph_lines: list[str] = []

    def flush_paragraph() -> None:
        if not paragraph_lines:
            return
        text = " ".join(part.strip() for part in paragraph_lines).strip()
        story.append(Paragraph(inline_markup(text), styles["Body"]))
        paragraph_lines.clear()

    index = 0
    while index < len(lines):
        raw = lines[index]
        line = raw.strip()
        next_line = lines[index + 1].strip() if index + 1 < len(lines) else ""

        if not line:
            flush_paragraph()
            index += 1
            continue

        heading_match = re.match(r"^(#{1,6})\s+(.+)$", line)
        if heading_match:
            flush_paragraph()
            level = min(len(heading_match.group(1)), 3)
            story.append(Paragraph(inline_markup(heading_match.group(2)), styles[f"Heading{level}"]))
            index += 1
            continue

        if "|" in line and is_table_separator(next_line):
            flush_paragraph()
            rows = [table_cells(line)]
            index += 2
            while index < len(lines) and "|" in lines[index] and lines[index].strip():
                rows.append(table_cells(lines[index]))
                index += 1
            story.append(Spacer(1, 3 * mm))
            story.append(make_table(rows, available_width, styles))
            story.append(Spacer(1, 3 * mm))
            continue

        bullet_match = re.match(r"^[-*]\s+(.+)$", line)
        numbered_match = re.match(r"^(\d+)\.\s+(.+)$", line)
        if bullet_match or numbered_match:
            flush_paragraph()
            if bullet_match:
                text = bullet_match.group(1)
                bullet = "•"
            else:
                text = numbered_match.group(2)
                bullet = f"{numbered_match.group(1)}."
            story.append(Paragraph(inline_markup(text), styles["List"], bulletText=bullet))
            index += 1
            continue

        if line.startswith(">"):
            flush_paragraph()
            story.append(Paragraph(inline_markup(line.lstrip("> ")), styles["Quote"]))
            index += 1
            continue

        paragraph_lines.append(line)
        index += 1

    flush_paragraph()
    return story


class ComplianceDocTemplate(BaseDocTemplate):
    def __init__(self, filename: str, **kwargs):
        super().__init__(filename, **kwargs)
        self._bookmark_counter = 0

    def beforeDocument(self):
        super().beforeDocument()
        self._bookmark_counter = 0

    def afterFlowable(self, flowable):
        if not isinstance(flowable, Paragraph):
            return
        style_name = flowable.style.name
        if style_name not in {"Heading1", "Heading2", "Heading3"}:
            return
        level = int(style_name[-1]) - 1
        title = flowable.getPlainText()
        self._bookmark_counter += 1
        key = f"heading-{self._bookmark_counter}"
        self.canv.bookmarkPage(key)
        self.canv.addOutlineEntry(title, key, level=level, closed=False)
        self.notify("TOCEntry", (level, title, self.page, key))


def register_fonts() -> None:
    pdfmetrics.registerFont(
        TTFont(
            "HeitiLight",
            "/System/Library/Fonts/STHeiti Light.ttc",
            subfontIndex=0,
        )
    )
    pdfmetrics.registerFont(
        TTFont(
            "HeitiMedium",
            "/System/Library/Fonts/STHeiti Medium.ttc",
            subfontIndex=0,
        )
    )


def build_styles() -> dict[str, ParagraphStyle]:
    sample = getSampleStyleSheet()
    return {
        "CoverBrand": ParagraphStyle(
            "CoverBrand",
            parent=sample["Normal"],
            fontName="HeitiMedium",
            fontSize=15,
            leading=20,
            textColor=BRAND,
            alignment=TA_CENTER,
        ),
        "CoverTitle": ParagraphStyle(
            "CoverTitle",
            parent=sample["Title"],
            fontName="HeitiMedium",
            fontSize=30,
            leading=40,
            textColor=INK,
            alignment=TA_CENTER,
            spaceAfter=8 * mm,
        ),
        "CoverMeta": ParagraphStyle(
            "CoverMeta",
            parent=sample["Normal"],
            fontName="HeitiLight",
            fontSize=11,
            leading=18,
            textColor=MUTED,
            alignment=TA_CENTER,
        ),
        "Heading1": ParagraphStyle(
            "Heading1",
            parent=sample["Heading1"],
            fontName="HeitiMedium",
            fontSize=20,
            leading=27,
            textColor=BRAND_DARK,
            spaceBefore=7 * mm,
            spaceAfter=4 * mm,
            keepWithNext=True,
        ),
        "Heading2": ParagraphStyle(
            "Heading2",
            parent=sample["Heading2"],
            fontName="HeitiMedium",
            fontSize=14,
            leading=20,
            textColor=INK,
            spaceBefore=5 * mm,
            spaceAfter=2.5 * mm,
            keepWithNext=True,
        ),
        "Heading3": ParagraphStyle(
            "Heading3",
            parent=sample["Heading3"],
            fontName="HeitiMedium",
            fontSize=11,
            leading=16,
            textColor=BRAND_DARK,
            spaceBefore=3.5 * mm,
            spaceAfter=1.5 * mm,
            keepWithNext=True,
        ),
        "Body": ParagraphStyle(
            "Body",
            parent=sample["BodyText"],
            fontName="HeitiLight",
            fontSize=9.2,
            leading=15.5,
            textColor=INK,
            alignment=TA_LEFT,
            spaceAfter=2.7 * mm,
            wordWrap="CJK",
        ),
        "List": ParagraphStyle(
            "List",
            parent=sample["BodyText"],
            fontName="HeitiLight",
            fontSize=9,
            leading=15,
            textColor=INK,
            leftIndent=7 * mm,
            firstLineIndent=0,
            bulletIndent=2 * mm,
            spaceAfter=1.5 * mm,
            wordWrap="CJK",
        ),
        "Quote": ParagraphStyle(
            "Quote",
            parent=sample["BodyText"],
            fontName="HeitiLight",
            fontSize=8.8,
            leading=14.5,
            textColor=MUTED,
            leftIndent=5 * mm,
            rightIndent=4 * mm,
            borderColor=BRAND,
            borderWidth=0,
            borderPadding=(3 * mm, 4 * mm, 3 * mm, 4 * mm),
            backColor=BRAND_LIGHT,
            spaceAfter=3 * mm,
            wordWrap="CJK",
        ),
        "Small": ParagraphStyle(
            "Small",
            parent=sample["BodyText"],
            fontName="HeitiLight",
            fontSize=7.6,
            leading=11.5,
            textColor=MUTED,
            wordWrap="CJK",
        ),
        "TOCHeading1": ParagraphStyle(
            "TOCHeading1",
            parent=sample["Normal"],
            fontName="HeitiMedium",
            fontSize=10.2,
            leading=15,
            leftIndent=0,
            firstLineIndent=0,
            textColor=INK,
        ),
        "TOCHeading2": ParagraphStyle(
            "TOCHeading2",
            parent=sample["Normal"],
            fontName="HeitiLight",
            fontSize=8.8,
            leading=13,
            leftIndent=5 * mm,
            firstLineIndent=0,
            textColor=MUTED,
        ),
        "TOCHeading3": ParagraphStyle(
            "TOCHeading3",
            parent=sample["Normal"],
            fontName="HeitiLight",
            fontSize=8.1,
            leading=12,
            leftIndent=10 * mm,
            firstLineIndent=0,
            textColor=MUTED,
        ),
    }


def draw_page(canvas, doc) -> None:
    width, height = canvas._pagesize
    canvas.saveState()
    canvas.setStrokeColor(LINE)
    canvas.setLineWidth(0.4)
    canvas.line(18 * mm, height - 15 * mm, width - 18 * mm, height - 15 * mm)
    canvas.setFont("HeitiLight", 7.5)
    canvas.setFillColor(MUTED)
    canvas.drawString(18 * mm, height - 11.5 * mm, "eSheep+ 3.1 个人信息保护合规工作包")
    canvas.drawRightString(width - 18 * mm, 10.5 * mm, f"第 {doc.page} 页")
    canvas.setStrokeColor(BRAND)
    canvas.setLineWidth(1.1)
    canvas.line(18 * mm, 15 * mm, width - 18 * mm, 15 * mm)
    canvas.restoreState()


def status_table(styles: dict[str, ParagraphStyle], width: float) -> Table:
    data = [
        ["工作项", "当前结论", "证据或边界"],
        ["中英文法律文本", "已起草", "版本 2026.09.01；真实主体、域名、服务地域待填"],
        ["App 分层告知与同意", "已实现", "核心条款/隐私与境外处理分别默认不勾选；AI 另行同意"],
        ["旧用户重新同意", "已实现", "版本或安全凭证不匹配时阻止进入工作区"],
        ["撤回同意", "已实现", "服务端留痕、本机凭证清理、停止 AI、退出账号"],
        ["Supabase 证据", "本地验证通过", "29 个迁移重放；101 项 pgTAP；0 个非 TODO 失败"],
        ["iOS 验证", "通过", "Debug 模拟器双架构构建；本次相关 6 个 XCTest 通过"],
        ["网站与 App Store", "预发布完成", "十个双语路由；390px/1440px 浏览器检查；问卷已生成"],
        ["正式发布", "仍被阻止", "P0 真实主体、邮箱、域名、生产地域、SMTP、MiMo 地域和合同未闭环"],
    ]
    return make_table(data, width, styles)


def release_blocker_table(styles: dict[str, ParagraphStyle], width: float) -> Table:
    data = [
        ["编号", "正式发布前必须取得的真实信息或证据", "负责人填写/签署"],
        ["P0-1", "个人信息处理者法定全称、注册地址、负责人、可长期收件邮箱", "________________"],
        ["P0-2", "正式 HTTPS 域名；中英文十个页面发布并完成中国大陆可达性测试", "________________"],
        ["P0-3", "Production Supabase 项目实际国家/地区、项目截图、DPA、子处理者清单", "________________"],
        ["P0-4", "SMTP 服务商、地域、隐私链接、保存期限和处理条款", "________________"],
        ["P0-5", "MiMo 当前 API 内容处理/存储地域的书面确认", "________________"],
        ["P0-6", "将 20260827224500 迁移部署到 Production，并复跑 RLS/越权/删除验证", "________________"],
        ["P0-7", "真机验证动态字体、VoiceOver、默认不勾选、拒绝、撤回、导出和删除", "________________"],
        ["P0-8", "隐私邮箱收发、权利请求、事件通知和一次桌面演练留痕", "________________"],
        ["P0-9", "实际负责人签署 PIA、自查表、内部制度与应急预案", "________________"],
    ]
    return make_table(data, width, styles)


def verification_table(styles: dict[str, ParagraphStyle], width: float) -> Table:
    data = [
        ["验证", "结果", "本次证据"],
        ["Privacy Manifest", "通过", "11 类收集数据；均为 App 功能；不跟踪"],
        ["法律网页生成", "通过", "Markdown 到 HTML 幂等；十个路由齐全；语言切换同名路由"],
        ["真实浏览器", "通过", "中文隐私页 390 x 844；英文 AI 页 1440 x 1000；控制台 0 错误"],
        ["Xcode build", "通过", "Debug generic iOS Simulator；arm64 + x86_64；CODE_SIGNING_ALLOWED=NO"],
        ["专项 XCTest", "通过", "LegalConsentTests 5 项 + AI 语音默认关闭 1 项；退出码 0"],
        ["Supabase 空库重放", "通过", "20260728131041 至 20260827224500 共 29 个迁移"],
        ["Supabase pgTAP", "通过", "6 文件；计划 101；TODO 1；非 TODO 失败 0"],
        ["Supabase advisors", "通过", "0 个问题"],
        ["Supabase lint", "有旧警告", "stage_farm_projection_batch 的 v_transition 未读取；与本次迁移无关"],
        ["正式发布门禁", "按预期失败", "未替换 P0 字段时，verify_privacy_compliance.sh 阻止发布"],
    ]
    return make_table(data, width, styles)


def build_pdf() -> Path:
    register_fonts()
    styles = build_styles()
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)

    portrait_size = A4
    landscape_size = landscape(A4)
    portrait_frame = Frame(
        18 * mm,
        18 * mm,
        portrait_size[0] - 36 * mm,
        portrait_size[1] - 36 * mm,
        leftPadding=0,
        rightPadding=0,
        topPadding=4 * mm,
        bottomPadding=2 * mm,
        id="portrait-frame",
    )
    landscape_frame = Frame(
        18 * mm,
        18 * mm,
        landscape_size[0] - 36 * mm,
        landscape_size[1] - 36 * mm,
        leftPadding=0,
        rightPadding=0,
        topPadding=4 * mm,
        bottomPadding=2 * mm,
        id="landscape-frame",
    )
    cover_frame = Frame(
        22 * mm,
        22 * mm,
        portrait_size[0] - 44 * mm,
        portrait_size[1] - 44 * mm,
        leftPadding=0,
        rightPadding=0,
        topPadding=0,
        bottomPadding=0,
        id="cover-frame",
    )

    doc = ComplianceDocTemplate(
        str(OUTPUT_PATH),
        pagesize=A4,
        title="eSheep+ 3.1 个人信息保护合规工作包",
        author="eSheep+ 预发布合规工程底稿",
        subject="隐私政策、个人信息清单、出境告知、PIA、自查、App Store 问卷和验证证据",
        leftMargin=18 * mm,
        rightMargin=18 * mm,
        topMargin=18 * mm,
        bottomMargin=18 * mm,
    )
    doc.addPageTemplates(
        [
            PageTemplate(id="cover", pagesize=portrait_size, frames=[cover_frame]),
            PageTemplate(id="portrait", pagesize=portrait_size, frames=[portrait_frame], onPage=draw_page),
            PageTemplate(id="landscape", pagesize=landscape_size, frames=[landscape_frame], onPage=draw_page),
        ]
    )

    portrait_width = portrait_size[0] - 36 * mm
    landscape_width = landscape_size[0] - 36 * mm
    story: list = []

    story.extend(
        [
            Spacer(1, 28 * mm),
            Paragraph("eSheep+ 3.1", styles["CoverBrand"]),
            Spacer(1, 8 * mm),
            Paragraph("个人信息保护<br/>合规工作包", styles["CoverTitle"]),
            Paragraph("法律文本版本 2026.09.01", styles["CoverMeta"]),
            Paragraph("审计基线日期 2026-08-27", styles["CoverMeta"]),
            Spacer(1, 16 * mm),
            Table(
                [[Paragraph("有条件通过 - P0 未关闭前禁止正式发布", styles["CoverMeta"])]],
                colWidths=[145 * mm],
                style=TableStyle(
                    [
                        ("BACKGROUND", (0, 0), (-1, -1), WARNING_LIGHT),
                        ("BOX", (0, 0), (-1, -1), 1, WARNING),
                        ("LEFTPADDING", (0, 0), (-1, -1), 8 * mm),
                        ("RIGHTPADDING", (0, 0), (-1, -1), 8 * mm),
                        ("TOPPADDING", (0, 0), (-1, -1), 5 * mm),
                        ("BOTTOMPADDING", (0, 0), (-1, -1), 5 * mm),
                    ]
                ),
            ),
            Spacer(1, 18 * mm),
            Paragraph(
                "工程化合规底稿 | 可编辑源文件另存于仓库 | 不是律师出具的法律意见",
                styles["CoverMeta"],
            ),
            Spacer(1, 6 * mm),
            Paragraph(
                "本工作包以真实代码、Supabase 本地迁移与测试、公开网站和 App Store 填报为依据。所有待填写字段均被明确标记，不以模板替代实际运营证据。",
                styles["CoverMeta"],
            ),
            NextPageTemplate("portrait"),
            PageBreak(),
        ]
    )

    story.append(Paragraph("目录", styles["Heading1"]))
    toc = TableOfContents()
    toc.levelStyles = [
        styles["TOCHeading1"],
        styles["TOCHeading2"],
        styles["TOCHeading3"],
    ]
    story.extend([toc, PageBreak()])

    story.extend(
        [
            Paragraph("一、交付结论", styles["Heading1"]),
            Paragraph(
                "这不是靠增加字数形成的长条款，而是一套把数据流、用户告知、权限、第三方、出境、AI、同意留痕、撤回、权利请求、审计和安全事件逐一对齐的合规工作包。技术部分已经形成可运行实现和本地证据；正式发布仍取决于运营主体才能提供的真实信息、Production 配置、合同和签署。",
                styles["Body"],
            ),
            status_table(styles, portrait_width),
            Paragraph("二、正式发布阻塞项", styles["Heading1"]),
            Paragraph(
                "下表任一 P0 未关闭时，不得把隐私政策当作正式生效文本，不得在 App Store Connect 提交占位信息，也不得对外宣称已完成合规审计。",
                styles["Quote"],
            ),
            release_blocker_table(styles, portrait_width),
            Paragraph("三、法律与工程边界", styles["Heading1"]),
            Paragraph(
                "截至 2026-08-27，处理不满 10 万自然人个人信息的境内处理者可按《小型个人信息处理者个人信息保护简化措施规定》使用简化表格和机制；该规定自 2026-09-01 施行。简化不等于免除告知、敏感信息单独同意、出境告知/单独同意、权利响应、安全保护和事件通知。涉及人数达到 10 万、处理重要数据或敏感信息出境门槛变化时，应重新判断适用制度。",
                styles["Body"],
            ),
            Paragraph(
                "官方依据：<link href=\"https://www.cac.gov.cn/2021-08/20/c_1631050028355286.htm\" color=\"#176B3A\"><u>《个人信息保护法》</u></link>；<link href=\"https://www.cac.gov.cn/2026-07/24/c_1786638889704872.htm\" color=\"#176B3A\"><u>《小型个人信息处理者个人信息保护简化措施规定》</u></link>；<link href=\"https://www.cac.gov.cn/2025-02/14/c_1741233507681519.htm\" color=\"#176B3A\"><u>《个人信息保护合规审计管理办法》</u></link>。",
                styles["Body"],
            ),
            Paragraph("四、实现与验证证据", styles["Heading1"]),
            verification_table(styles, portrait_width),
            Paragraph("五、材料维护规则", styles["Heading1"]),
            Paragraph(
                "法律文本统一版本为 2026.09.01。处理目的、方式、种类、保存期限、接收方、境外地点或用户权益发生实质变化时，应提升对应版本、更新 App/网站/App Store/Manifest，并在法律要求时重新取得同意或单独同意。每次发版运行 tools/verify_privacy_compliance.sh；占位符存在时，该脚本按设计阻止正式发布。",
                styles["Body"],
            ),
        ]
    )

    current_template = "portrait"
    for appendix_title, relative_path, orientation in SOURCE_DOCUMENTS:
        if orientation != current_template:
            story.extend([NextPageTemplate(orientation), PageBreak()])
            current_template = orientation
        else:
            story.append(PageBreak())

        available_width = landscape_width if orientation == "landscape" else portrait_width
        source_path = REPOSITORY_ROOT / relative_path
        source_text = source_path.read_text(encoding="utf-8")
        story.append(Paragraph(appendix_title, styles["Heading1"]))
        story.append(
            Paragraph(
                inline_markup(f"可编辑源文件: {relative_path}"),
                styles["Small"],
            )
        )
        story.extend(markdown_story(source_text, available_width, styles))

    story.extend(
        [
            NextPageTemplate("portrait"),
            PageBreak(),
            Paragraph("最终签署页", styles["Heading1"]),
            Paragraph(
                "本人确认已核对本工作包与 eSheep+ 实际线上处理活动、Production 配置和合同证据；所有待填写字段已替换，P0 项已关闭，网站与 App Store 信息一致。",
                styles["Body"],
            ),
            Spacer(1, 10 * mm),
            make_table(
                [
                    ["签署事项", "填写"],
                    ["个人信息处理者", "________________________________________"],
                    ["个人信息保护负责人", "________________________________________"],
                    ["版本", "2026.09.01"],
                    ["签字", "________________________________________"],
                    ["日期", "________ 年 ____ 月 ____ 日"],
                    ["复核意见", "________________________________________\n________________________________________"],
                ],
                portrait_width,
                styles,
            ),
        ]
    )

    doc.multiBuild(story)
    return OUTPUT_PATH


if __name__ == "__main__":
    path = build_pdf()
    print(path)
