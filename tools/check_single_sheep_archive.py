#!/usr/bin/env python3
"""Independently inspect real synthetic XLSX files extracted from XCTest results.

Uses Python's ZIP/XML readers, not the app's XLSXCodec. Never generates substitute
workbooks. Fails if XCTest did not produce the expected synthetic artifacts.
"""
import json
import sys
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"


def parse_workbook(path):
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None, f"CRC failure: {path}"
        workbook = ET.fromstring(archive.read("xl/workbook.xml"))
        relationships = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
        targets = {item.attrib["Id"]: item.attrib["Target"] for item in relationships}
        result = {}
        for sheet in workbook.findall("s:sheets/s:sheet", NS):
            target = targets[sheet.attrib[REL]]
            xml = ET.fromstring(archive.read("xl/" + target))
            assert not xml.findall(".//s:f", NS), "Archive cells must be literal, not formulas"
            rows = []
            for row in xml.findall("s:sheetData/s:row", NS):
                cells = []
                for cell in row.findall("s:c", NS):
                    assert cell.attrib.get("t") == "inlineStr", "Unexpected archive cell type"
                    cells.append("".join(cell.find("s:is", NS).itertext()))
                rows.append(cells)
            result[sheet.attrib["name"]] = rows
        return result


def verify(directory):
    reports = []
    subjects = {}
    for path in sorted(directory.rglob("*")):
        if not path.is_file() or not zipfile.is_zipfile(path):
            continue
        with zipfile.ZipFile(path) as archive:
            if "xl/workbook.xml" not in archive.namelist():
                continue
        sheets = parse_workbook(path)
        profile = sheets["单羊档案"]
        tag = profile[0][1]
        assert tag.startswith("SYN-"), "Only synthetic fixture archives are accepted"
        assert not any("FORBIDDEN" in cell for rows in sheets.values() for row in rows for cell in row)
        fields = {row[0]: row[1] for row in profile}
        if tag == "SYN-001":
            assert fields["出生日期"] == "2023-01-01 00:30"
            assert len(sheets["健康记录"]) == 3
            assert len(sheets["繁殖记录"]) == 6
        if tag == "SYN-DST":
            assert fields["入场时间"] == "2024-11-02 23:30"
            header, *rows = sheets["体重记录"]
            assert len(rows) == 2
            assert [row[header.index("发生时间")] for row in rows] == ["2024-11-03 01:30"] * 2
        if tag == "SYN-LONG":
            assert len(sheets["体重记录"]) == 151
            assert fields["备注"].startswith("=HYPERLINK(")
        if tag == "SYN-SIRE":
            header, *rows = sheets["繁殖记录"]
            assert len(rows) == 1 and rows[0][header.index("类型")] == "配种"
        subjects[tag] = subjects.get(tag, 0) + 1
        reports.append({"file": str(path), "subject": tag, "sheets": {name: len(rows) for name, rows in sheets.items()}})
    assert subjects.get("SYN-001", 0) >= 4, "Missing role or mixed-input workbooks"
    for tag in ["SYN-SIRE", "SYN-DST", "SYN-LONG"]:
        assert subjects.get(tag, 0) >= 1, f"Missing actual workbook: {tag}"
    print(json.dumps({"workbooks_verified": len(reports), "artifacts": reports}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    verify(Path(sys.argv[1]))
