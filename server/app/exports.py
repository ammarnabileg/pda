"""Excel and PDF of any dashboard page, in one Arabic design.

A page builds a Report (title, info lines, tables); to_xlsx / to_pdf turn it into a file.
Excel: right-to-left sheet, styled header, number formats, totals.
PDF: A4 (landscape for wide tables), Noto Sans Arabic, letters joined and lines laid out right to left,
co-op name and date on every page, page numbers, repeated table headers, zebra rows, totals, signatures.
"""
import io
import re
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal
from xml.sax.saxutils import escape

from . import config

BRAND = "0F3D33"     # dashboard sidebar green
BRAND_2 = "E3EEEA"   # light green
ZEBRA = "F5F8F7"
LINE = "D5DDDA"


@dataclass
class Col:
    label: str
    kind: str = "text"   # text | money | qty | int
    width: float = 1.0   # relative width in the PDF


@dataclass
class Table:
    columns: list
    rows: list
    title: str = ""
    totals: list | None = None


@dataclass
class Report:
    title: str
    filename: str
    subtitle: str = ""
    info: list = field(default_factory=list)       # [(label, value)]
    tables: list = field(default_factory=list)
    note: str = ""
    signatures: list = field(default_factory=list)  # ["توقيع ...", ...]


def _num(v, kind):
    if v is None or v == "":
        return ""
    if kind == "money":
        return f"{Decimal(v):,.3f}"
    if kind == "qty":
        d = Decimal(v)
        return f"{d:,.0f}" if d == d.to_integral_value() else f"{d:,.3f}".rstrip("0").rstrip(".")
    if kind == "int":
        return f"{int(v):,}"
    return str(v)


def _text(v):
    if v is None:
        return ""
    if isinstance(v, datetime):
        return v.strftime("%Y-%m-%d %H:%M")
    if isinstance(v, date):
        return v.isoformat()
    return str(v)


# ---------- Excel ----------

def to_xlsx(rep: Report) -> bytes:
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from openpyxl.utils import get_column_letter

    wb = Workbook()
    ws = wb.active
    ws.title = re.sub(r"[\[\]:*?/\\]", " ", rep.title)[:31] or "تقرير"
    ws.sheet_view.rightToLeft = True
    width = max([len(t.columns) for t in rep.tables] + [2])
    bold, head_font = Font(name="Arial", bold=True, size=11), Font(name="Arial", bold=True, color="FFFFFF", size=11)
    head_fill, zebra, total_fill = (PatternFill("solid", fgColor=c) for c in (BRAND, ZEBRA, BRAND_2))
    thin = Side(style="thin", color=LINE)
    box = Border(left=thin, right=thin, top=thin, bottom=thin)
    right = Alignment(horizontal="right", vertical="center", wrap_text=True)
    widths = [10] * (width + 1)
    r = 1

    def line(value, font=None, size=None):
        nonlocal r
        c = ws.cell(row=r, column=1, value=value)
        c.font = font or Font(name="Arial", bold=True, size=size or 12)
        c.alignment = Alignment(horizontal="right")
        ws.merge_cells(start_row=r, start_column=1, end_row=r, end_column=width)
        r += 1

    line(config.COOP_NAME, size=12)
    line(rep.title, size=16)
    if rep.subtitle:
        line(rep.subtitle, Font(name="Arial", size=11, color="555555"))
    line(f"تاريخ الاستخراج: {datetime.now():%Y-%m-%d %H:%M}", Font(name="Arial", size=10, color="777777"))
    for label, value in rep.info:
        ws.cell(row=r, column=1, value=label).font = bold
        ws.cell(row=r, column=2, value=_text(value)).alignment = right
        ws.merge_cells(start_row=r, start_column=2, end_row=r, end_column=max(2, width))
        r += 1
    first_header = None
    for t in rep.tables:
        r += 1
        if t.title:
            line(t.title, size=12)
        for i, col in enumerate(t.columns, start=1):
            c = ws.cell(row=r, column=i, value=col.label)
            c.font, c.fill, c.border, c.alignment = head_font, head_fill, box, Alignment(horizontal="center", vertical="center", wrap_text=True)
            widths[i] = max(widths[i], min(len(col.label) + 4, 40))
        first_header = first_header or r
        r += 1
        for n, row in enumerate(t.rows + ([t.totals] if t.totals else [])):
            is_total = t.totals is not None and n == len(t.rows)
            for i, (col, v) in enumerate(zip(t.columns, row), start=1):
                if col.kind in ("money", "qty", "int") and v not in (None, ""):
                    c = ws.cell(row=r, column=i, value=float(v))
                    c.number_format = {"money": "#,##0.000", "qty": "#,##0.###", "int": "#,##0"}[col.kind]
                    c.alignment = Alignment(horizontal="left", vertical="center")
                else:
                    c = ws.cell(row=r, column=i, value=_text(v))
                    c.alignment = right
                c.border = box
                if is_total:
                    c.font, c.fill = bold, total_fill
                elif n % 2:
                    c.fill = zebra
                widths[i] = max(widths[i], min(len(_text(v) if col.kind == "text" else _num(v, col.kind)) + 3, 60))
            r += 1
    if rep.note:
        r += 1
        line(rep.note, Font(name="Arial", size=10, color="555555"))
    for i in range(1, width + 1):
        ws.column_dimensions[get_column_letter(i)].width = widths[i]
    if len(rep.tables) == 1 and first_header:
        ws.freeze_panes = ws.cell(row=first_header + 1, column=1)
        t = rep.tables[0]
        ws.auto_filter.ref = f"A{first_header}:{get_column_letter(len(t.columns))}{first_header + len(t.rows)}"
    ws.page_setup.orientation = "landscape" if width > 7 else "portrait"
    ws.page_setup.fitToWidth, ws.page_setup.fitToHeight = 1, 0
    ws.sheet_properties.pageSetUpPr.fitToPage = True
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


# ---------- PDF ----------

_FONTS = False
ARABIC = re.compile(r"[؀-ۿ]")


def _fonts():
    global _FONTS
    if not _FONTS:
        from reportlab.pdfbase import pdfmetrics
        from reportlab.pdfbase.ttfonts import TTFont

        d = config.BASE_DIR / "app" / "static" / "fonts"
        pdfmetrics.registerFont(TTFont("Ar", str(d / "NotoSansArabic-Regular.ttf")))
        pdfmetrics.registerFont(TTFont("ArB", str(d / "NotoSansArabic-Bold.ttf")))
        _FONTS = True


def ar(text) -> str:
    """Arabic for drawing: letters joined (presentation forms) and the line in visual right-to-left order."""
    s = _text(text)
    if not ARABIC.search(s):
        return s
    import arabic_reshaper
    from bidi.algorithm import get_display

    return get_display(arabic_reshaper.reshape(s))


def _lines(text, font, size, width):
    """Wrap in logical order first, then shape each line, so wrapped Arabic reads top to bottom correctly."""
    from reportlab.pdfbase.pdfmetrics import stringWidth

    out = []
    for para in _text(text).split("\n"):
        cur = ""
        for word in para.split(" "):
            test = f"{cur} {word}".strip()
            if cur and stringWidth(ar(test), font, size) > width:
                out.append(cur)
                cur = word
            else:
                cur = test
        out.append(cur)
    return [ar(x) for x in out]


def to_pdf(rep: Report) -> bytes:
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_CENTER, TA_LEFT, TA_RIGHT
    from reportlab.lib.pagesizes import A4, landscape
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.lib.units import mm
    from reportlab.platypus import KeepTogether, Paragraph, SimpleDocTemplate, Spacer, Table as RLTable, TableStyle

    _fonts()
    wide = max([len(t.columns) for t in rep.tables] + [0]) > 7
    page = landscape(A4) if wide else A4
    margin = 14 * mm
    usable = page[0] - 2 * margin
    brand, brand2, zebra, line = (colors.HexColor("#" + c) for c in (BRAND, BRAND_2, ZEBRA, LINE))

    def style(size=9.5, bold=False, align=TA_RIGHT, color=colors.black):
        return ParagraphStyle("s", fontName="ArB" if bold else "Ar", fontSize=size, leading=size * 1.55,
                              alignment=align, textColor=color)

    def para(text, st, width=None):
        if width is None:
            return Paragraph(escape(ar(text)), st)
        # Wrapped here, slightly narrower than the cell, so reportlab never re-wraps (it would reverse shaped lines).
        return Paragraph("<br/>".join(escape(x) for x in _lines(text, st.fontName, st.fontSize, width * 0.95)), st)

    story = [para(rep.title, style(17, True, TA_CENTER, brand))]
    if rep.subtitle:
        story.append(para(rep.subtitle, style(10.5, align=TA_CENTER, color=colors.HexColor("#555555"))))
    story.append(Spacer(1, 4 * mm))
    if rep.info:
        cells, row = [], []
        for label, value in rep.info:
            row += [para(label, style(9.5, True, color=brand), usable * 0.17 - 10), para(_text(value), style(10), usable * 0.33 - 10)]
            if len(row) == 4:
                cells.append(row)
                row = []
        if row:
            cells.append(row + [""] * (4 - len(row)))
        cells = [list(reversed(c)) for c in cells]
        # After reversing, each pair reads label then value from the right: [value2, label2, value1, label1].
        info = RLTable(cells, colWidths=[usable * 0.33, usable * 0.17] * 2)
        info.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), brand2), ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                                  ("BOX", (0, 0), (-1, -1), 0.5, line), ("INNERGRID", (0, 0), (-1, -1), 0.25, colors.white),
                                  ("TOPPADDING", (0, 0), (-1, -1), 3), ("BOTTOMPADDING", (0, 0), (-1, -1), 3)]))
        story += [info, Spacer(1, 5 * mm)]

    for t in rep.tables:
        if t.title:
            story += [para(t.title, style(12, True, color=brand)), Spacer(1, 1.5 * mm)]
        total_w = sum(c.width for c in t.columns) or 1
        widths = [usable * c.width / total_w for c in t.columns]
        head = [para(c.label, style(9, True, TA_CENTER, colors.white), w - 6) for c, w in zip(t.columns, widths)]
        body = []
        for row in t.rows + ([t.totals] if t.totals else []):
            cells = []
            for c, w, v in zip(t.columns, widths, row):
                if c.kind == "text":
                    cells.append(para(_text(v), style(9), w - 6))
                else:
                    cells.append(Paragraph(escape(_num(v, c.kind)), style(9, align=TA_LEFT)))
            body.append(cells)
        if t.totals:
            for i, cell in enumerate(body[-1]):
                cell.style = ParagraphStyle("t", parent=cell.style, fontName="ArB")
        data = [list(reversed(r)) for r in [head] + body]   # first column on the right
        tbl = RLTable(data, colWidths=list(reversed(widths)), repeatRows=1)
        cmds = [("BACKGROUND", (0, 0), (-1, 0), brand), ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("GRID", (0, 0), (-1, -1), 0.4, line), ("TOPPADDING", (0, 0), (-1, -1), 2.5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2.5), ("LEFTPADDING", (0, 0), (-1, -1), 3),
                ("RIGHTPADDING", (0, 0), (-1, -1), 3)]
        cmds += [("BACKGROUND", (0, i), (-1, i), zebra) for i in range(2, len(data), 2)]
        if t.totals:
            cmds.append(("BACKGROUND", (0, len(data) - 1), (-1, len(data) - 1), brand2))
        if not t.rows:
            data.append([para("لا يوجد", style(9, align=TA_CENTER))] + [""] * (len(t.columns) - 1))
            cmds.append(("SPAN", (0, len(data) - 1), (-1, len(data) - 1)))
            tbl = RLTable(data, colWidths=list(reversed(widths)), repeatRows=1)
        tbl.setStyle(TableStyle(cmds))
        story += [tbl, Spacer(1, 6 * mm)]

    if rep.note:
        story += [para(rep.note, style(9.5, color=colors.HexColor("#444444")), usable), Spacer(1, 4 * mm)]
    if rep.signatures:
        n = len(rep.signatures)
        cw = usable / n
        inner = []
        for s_ in reversed(rep.signatures):
            box = RLTable([[""], [para(s_, style(10, align=TA_CENTER), cw - 50)]], colWidths=[cw - 30])
            box.setStyle(TableStyle([("LINEABOVE", (0, 1), (0, 1), 0.8, colors.black), ("TOPPADDING", (0, 1), (0, 1), 5)]))
            inner.append(box)
        sig = RLTable([inner], colWidths=[cw] * n)
        story += [Spacer(1, 14 * mm), KeepTogether(sig)]

    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")

    def frame(canvas, doc):
        canvas.saveState()
        w, h = page
        canvas.setFillColor(brand)
        canvas.rect(0, h - 9 * mm, w, 9 * mm, fill=1, stroke=0)
        canvas.setFillColor(colors.white)
        canvas.setFont("ArB", 10.5)
        canvas.drawRightString(w - margin, h - 6.2 * mm, ar(config.COOP_NAME))
        canvas.setFont("Ar", 9)
        canvas.drawString(margin, h - 6.2 * mm, ar(f"استخراج {stamp}"))
        canvas.setFillColor(colors.HexColor("#777777"))
        canvas.setStrokeColor(line)
        canvas.line(margin, 11 * mm, w - margin, 11 * mm)
        canvas.drawCentredString(w / 2, 6.5 * mm, ar(f"صفحة {doc.page}"))
        canvas.drawRightString(w - margin, 6.5 * mm, ar(rep.title))
        canvas.drawString(margin, 6.5 * mm, "Tamween")
        canvas.restoreState()

    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=page, leftMargin=margin, rightMargin=margin, topMargin=16 * mm,
                            bottomMargin=16 * mm, title=rep.title, author=config.COOP_NAME)
    doc.build(story, onFirstPage=frame, onLaterPages=frame)
    return buf.getvalue()
