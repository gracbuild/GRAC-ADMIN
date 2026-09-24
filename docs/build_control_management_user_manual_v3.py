"""
Builds GRAC_RepositoryManagement_UserManual_v3.docx  (Control Management module).

Fresh, full end-user manual written screen-by-screen from the current source:
  src/ControlManagement.Web/Models/RepositoryScreen.cs   (screen catalogue)
  src/ControlManagement.Web/wwwroot/js/repository.js      (field schemas, row actions)
  src/ControlManagement.Web/Views/**                      (full-page forms)
  src/ControlManagement.Api/Services/BulkUploadSchema.cs  (bulk workbook)
  src/ControlManagement.Api/Services/SingleFormUploadSchema.cs

House style follows build_repository_user_manual_v2.py (Calibri, navy/blue
headings, shaded table headers, callout boxes, screenshot placeholders).

Run:  python build_user_manual_v3.py
"""

from pathlib import Path
from docx import Document
from docx.shared import Inches, Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_CELL_VERTICAL_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
import sys

OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("GRAC_RepositoryManagement_UserManual_v3.docx")

NAVY = "0B2545"; BLUE = "2E74B5"; DARK_BLUE = "1F4D78"; MUTED = "667085"
HEADER_FILL = "E8EEF5"; LIGHT_FILL = "F4F6F9"; WARN_FILL = "FFF8E8"; NEW_FILL = "EAF4EC"

PAGE_W = 9360  # usable width in dxa with 1" margins


# ---------------------------------------------------------------------------
# Low-level docx helpers
# ---------------------------------------------------------------------------

def set_cell_shading(cell, fill):
    """Set cell shading, keeping w:shd in its schema-mandated position.

    tcPr children are order-sensitive: shd must sit after tcBorders and before
    noWrap / tcMar / vAlign.  Appending it blindly produces a file Word opens
    but a validator rejects, so insert it ahead of the first later sibling.
    """
    tcPr = cell._tc.get_or_add_tcPr()
    shd = tcPr.find(qn("w:shd"))
    if shd is None:
        shd = OxmlElement("w:shd")
        follows = ["w:noWrap", "w:tcMar", "w:textDirection", "w:tcFitText",
                   "w:vAlign", "w:hideMark"]
        anchor = next((tcPr.find(qn(tag)) for tag in follows
                       if tcPr.find(qn(tag)) is not None), None)
        if anchor is not None:
            anchor.addprevious(shd)
        else:
            tcPr.append(shd)
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)


def set_cell_margin(cell, top=80, start=120, bottom=80, end=120):
    tcPr = cell._tc.get_or_add_tcPr()
    tcMar = tcPr.first_child_found_in("w:tcMar")
    if tcMar is None:
        tcMar = OxmlElement("w:tcMar"); tcPr.append(tcMar)
    for m, v in [("top", top), ("start", start), ("bottom", bottom), ("end", end)]:
        node = tcMar.find(qn(f"w:{m}"))
        if node is None:
            node = OxmlElement(f"w:{m}"); tcMar.append(node)
        node.set(qn("w:w"), str(v)); node.set(qn("w:type"), "dxa")


# tblPr children are order-sensitive; python-docx appends them as they are set,
# which produces a file Word opens happily but a validator rejects.  Sort them
# back into schema order once the table is fully configured.
TBLPR_ORDER = ["w:tblStyle", "w:tblpPr", "w:tblOverlap", "w:bidiVisual",
               "w:tblStyleRowBandSize", "w:tblStyleColBandSize", "w:tblW", "w:jc",
               "w:tblCellSpacing", "w:tblInd", "w:tblBorders", "w:shd",
               "w:tblLayout", "w:tblCellMar", "w:tblLook", "w:tblCaption",
               "w:tblDescription", "w:tblPrChange"]


def normalize_tbl_pr(table_):
    tblPr = table_._tbl.tblPr
    rank = {qn(tag): i for i, tag in enumerate(TBLPR_ORDER)}
    children = list(tblPr)
    children.sort(key=lambda el: rank.get(el.tag, len(rank)))
    for child in children:
        tblPr.append(child)


def set_table_geometry(table_, widths):
    table_.alignment = WD_TABLE_ALIGNMENT.LEFT
    table_.autofit = False
    tblPr = table_._tbl.tblPr
    tblW = tblPr.find(qn("w:tblW"))
    if tblW is None:
        tblW = OxmlElement("w:tblW"); tblPr.append(tblW)
    tblW.set(qn("w:w"), str(sum(widths))); tblW.set(qn("w:type"), "dxa")
    tblInd = tblPr.find(qn("w:tblInd"))
    if tblInd is None:
        tblInd = OxmlElement("w:tblInd"); tblPr.append(tblInd)
    tblInd.set(qn("w:w"), "120"); tblInd.set(qn("w:type"), "dxa")
    for col, width in zip(table_._tbl.tblGrid.gridCol_lst, widths):
        col.set(qn("w:w"), str(width))
    for row in table_.rows:
        for cell, width in zip(row.cells, widths):
            tcPr = cell._tc.get_or_add_tcPr()
            tcW = tcPr.find(qn("w:tcW"))
            if tcW is None:
                tcW = OxmlElement("w:tcW"); tcPr.append(tcW)
            tcW.set(qn("w:w"), str(width)); tcW.set(qn("w:type"), "dxa")
            set_cell_margin(cell)
            cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
    normalize_tbl_pr(table_)


def mark_header_row(row):
    trPr = row._tr.get_or_add_trPr()
    el = OxmlElement("w:tblHeader"); el.set(qn("w:val"), "true")
    trPr.append(el)


def set_font(run, name="Calibri", size=11, color=None, bold=None, italic=None):
    run.font.name = name
    run._element.rPr.rFonts.set(qn("w:ascii"), name)
    run._element.rPr.rFonts.set(qn("w:hAnsi"), name)
    run.font.size = Pt(size)
    if color:
        run.font.color.rgb = RGBColor.from_string(color)
    if bold is not None:
        run.bold = bold
    if italic is not None:
        run.italic = italic


def style_para(p, before=0, after=6, line=1.25):
    p.paragraph_format.space_before = Pt(before)
    p.paragraph_format.space_after = Pt(after)
    p.paragraph_format.line_spacing = line


def para(doc, text="", bold=False, color=None, size=11, align=None,
         before=0, after=6, italic=False):
    p = doc.add_paragraph(); style_para(p, before, after)
    if align is not None:
        p.alignment = align
    set_font(p.add_run(text), size=size, color=color, bold=bold, italic=italic)
    return p


def bullet(doc, text):
    p = doc.add_paragraph(style="List Bullet"); style_para(p, after=4)
    set_font(p.add_run(text), size=11)


# --- numbered lists that restart at 1 for every block -----------------------
# python-docx's "List Number" style shares a single numbering sequence across
# the whole document, so consecutive procedures would count 1, 2, 3 ... 174.
# We define our own abstract numbering once, then hand each list block its own
# w:num instance, which restarts it.  A block ends as soon as a paragraph that
# is not a numbered step is written - detected from the previous element - so
# call sites need no bookkeeping.

_NUM = {"abstract": None, "next_id": 900, "last_p": None, "last_num": None}


def _ensure_abstract_numbering(doc):
    if _NUM["abstract"] is not None:
        return _NUM["abstract"]
    numbering = doc.part.numbering_part.element
    existing = [int(a.get(qn("w:abstractNumId")))
                for a in numbering.findall(qn("w:abstractNum"))]
    aid = (max(existing) + 1) if existing else 0
    abstract = OxmlElement("w:abstractNum")
    abstract.set(qn("w:abstractNumId"), str(aid))
    for level in range(3):
        lvl = OxmlElement("w:lvl"); lvl.set(qn("w:ilvl"), str(level))
        start = OxmlElement("w:start"); start.set(qn("w:val"), "1"); lvl.append(start)
        fmt = OxmlElement("w:numFmt"); fmt.set(qn("w:val"), "decimal"); lvl.append(fmt)
        txt = OxmlElement("w:lvlText"); txt.set(qn("w:val"), "%%%d." % (level + 1)); lvl.append(txt)
        jc = OxmlElement("w:lvlJc"); jc.set(qn("w:val"), "left"); lvl.append(jc)
        pPr = OxmlElement("w:pPr")
        ind = OxmlElement("w:ind")
        ind.set(qn("w:left"), str(360 + level * 360)); ind.set(qn("w:hanging"), "360")
        pPr.append(ind); lvl.append(pPr)
        abstract.append(lvl)
    first_num = numbering.find(qn("w:num"))
    if first_num is not None:
        first_num.addprevious(abstract)
    else:
        numbering.append(abstract)
    _NUM["abstract"] = aid
    return aid


def _new_num_id(doc):
    aid = _ensure_abstract_numbering(doc)
    numbering = doc.part.numbering_part.element
    _NUM["next_id"] += 1
    num_id = _NUM["next_id"]
    num = OxmlElement("w:num"); num.set(qn("w:numId"), str(num_id))
    ref = OxmlElement("w:abstractNumId"); ref.set(qn("w:val"), str(aid))
    num.append(ref)
    # Several w:num entries sharing one abstractNum keep counting as a single
    # sequence unless each one explicitly overrides the start value.  This is
    # what actually makes the list restart at 1.
    for level in range(3):
        override = OxmlElement("w:lvlOverride")
        override.set(qn("w:ilvl"), str(level))
        start_override = OxmlElement("w:startOverride")
        start_override.set(qn("w:val"), "1")
        override.append(start_override)
        num.append(override)
    numbering.append(num)
    return num_id


def step(doc, text):
    """One numbered step. A run of consecutive step() calls shares a numbering
    instance; the first call after any other content starts a fresh one at 1."""
    # w:body always ends with w:sectPr, so walk back past it to find the last
    # real block-level element.
    body = doc.element.body
    last_child = next((child for child in reversed(body)
                       if child.tag in (qn("w:p"), qn("w:tbl"))), None)
    continuing = last_child is not None and last_child is _NUM.get("last_p")
    num_id = _NUM["last_num"] if continuing else _new_num_id(doc)

    p = doc.add_paragraph(); style_para(p, after=4)
    p.paragraph_format.left_indent = Pt(24)
    p.paragraph_format.first_line_indent = Pt(-18)
    pPr = p._p.get_or_add_pPr()
    numPr = OxmlElement("w:numPr")
    ilvl = OxmlElement("w:ilvl"); ilvl.set(qn("w:val"), "0"); numPr.append(ilvl)
    nid = OxmlElement("w:numId"); nid.set(qn("w:val"), str(num_id)); numPr.append(nid)
    pPr.insert(0, numPr)
    set_font(p.add_run(text), size=11)
    _NUM["last_p"] = p._p
    _NUM["last_num"] = num_id
    return p


def heading(doc, text, level=1):
    p = doc.add_paragraph(style=f"Heading {level}")
    p.add_run(text)
    return p


def table(doc, headers, rows, widths):
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = "Table Grid"
    set_table_geometry(t, widths)
    mark_header_row(t.rows[0])
    for i, h in enumerate(headers):
        set_cell_shading(t.rows[0].cells[i], HEADER_FILL)
        p = t.rows[0].cells[i].paragraphs[0]; style_para(p, after=0, line=1.0)
        set_font(p.add_run(h), size=9.5, bold=True, color=NAVY)
    for row in rows:
        cells = t.add_row().cells
        for i, value in enumerate(row):
            p = cells[i].paragraphs[0]; style_para(p, after=0, line=1.0)
            set_font(p.add_run(str(value)), size=9.2)
    set_table_geometry(t, widths)
    doc.add_paragraph()
    return t


def callout(doc, title, text, fill=LIGHT_FILL):
    t = doc.add_table(rows=1, cols=1)
    set_table_geometry(t, [PAGE_W])
    set_cell_shading(t.cell(0, 0), fill)
    p = t.cell(0, 0).paragraphs[0]; style_para(p, after=2)
    set_font(p.add_run(title + ": "), size=10.5, bold=True, color=DARK_BLUE)
    set_font(p.add_run(text), size=10.5)
    doc.add_paragraph()


def screenshot(doc, caption):
    t = doc.add_table(rows=1, cols=1)
    set_table_geometry(t, [PAGE_W])
    set_cell_shading(t.cell(0, 0), LIGHT_FILL)
    p = t.cell(0, 0).paragraphs[0]; style_para(p, after=2)
    set_font(p.add_run("[Screenshot Placeholder]  "), size=10, bold=True, color=MUTED)
    set_font(p.add_run(caption), size=10, italic=True, color=MUTED)
    doc.add_paragraph()


def toc_field(doc):
    p = doc.add_paragraph()
    r = p.add_run()
    fld_begin = OxmlElement("w:fldChar"); fld_begin.set(qn("w:fldCharType"), "begin")
    instr = OxmlElement("w:instrText"); instr.set(qn("xml:space"), "preserve")
    instr.text = r'TOC \o "1-3" \h \z \u'
    fld_sep = OxmlElement("w:fldChar"); fld_sep.set(qn("w:fldCharType"), "separate")
    fld_end = OxmlElement("w:fldChar"); fld_end.set(qn("w:fldCharType"), "end")
    r._r.append(fld_begin); r._r.append(instr); r._r.append(fld_sep); r._r.append(fld_end)


# ---------------------------------------------------------------------------
# Reusable blocks
# ---------------------------------------------------------------------------

FIELD_HEADERS = ["Field", "Required", "What to enter"]
FIELD_WIDTHS = [2300, 1100, 5960]

STD_ADD = [
    "Open the screen from the left menu.",
    "Click Add in the top-right of the page heading. A dialog opens with the fields listed above.",
    "Complete every field marked with a red asterisk (*). Dropdowns are fed from the repository - if a value "
    "is missing, create it on its own screen first.",
    "Click Save.",
    "Read the confirmation. If your role is a maker on this module you will see 'Change submitted for "
    "approval'; if approval is not required you will see 'Change saved and auto-approved'.",
]

STD_EDIT = [
    "Find the row in the grid (use Search or the filters).",
    "Click the 3-dot menu at the right end of the row and choose Edit.",
    "The dialog opens pre-filled with the current values. Change what you need.",
    "Click Save. The same approval message appears as on Add.",
]

STD_VIEW = [
    "Click the 3-dot menu on the row and choose View. The dialog opens read-only with a 'View Mode' chip "
    "beside the title.",
    "If you have Edit rights, the Edit button in the top-right of the dialog switches it to editable without "
    "closing and reopening.",
    "Click Cancel / Back or the x to close.",
]

STD_INACTIVE = [
    "Click the 3-dot menu on the row and choose Inactive.",
    "Read the confirmation message and click Mark Inactive. Historical data and child records stay in the "
    "database; the record simply stops appearing in lookups and new mappings.",
    "To bring it back later, filter the grid by the inactive status, open the 3-dot menu on the row and "
    "choose Activate.",
]

AUDIT_STD = ("Every Add, Edit, Inactive and Activate writes an audit header row plus one field-level row per "
             "changed value (Old Value to New Value). Both are visible on the Audit Traceability screen, "
             "filterable by module/entity, action type and date.")


def steps_block(doc, title, lines):
    heading(doc, title, 3)
    for line in lines:
        step(doc, line)


def screen_section(doc, number, title, menu_path, purpose, when, fields, rules,
                   audit=AUDIT_STD, standard_crud=True, extra=None, shot=None,
                   row_actions=None):
    """Render one screen chapter in the standard layout."""
    heading(doc, f"{number} {title}", 2)
    heading(doc, "What this screen is for", 3)
    para(doc, purpose)
    if menu_path:
        para(doc, f"Menu path: {menu_path}", italic=True, color=MUTED, size=10)
    if when:
        heading(doc, "When to use it", 3)
        para(doc, when)
    if fields:
        heading(doc, "Fields on the form", 3)
        table(doc, FIELD_HEADERS, fields, FIELD_WIDTHS)
    if standard_crud:
        steps_block(doc, "Add a record", STD_ADD)
        steps_block(doc, "Edit a record", STD_EDIT)
        steps_block(doc, "View a record", STD_VIEW)
        steps_block(doc, "Make a record inactive (and reactivate it)", STD_INACTIVE)
    if row_actions:
        heading(doc, "Extra actions on the 3-dot menu", 3)
        table(doc, ["Action", "What it does"], row_actions, [2600, 6760])
    if extra:
        for block_title, lines, kind in extra:
            if kind == "steps":
                steps_block(doc, block_title, lines)
            elif kind == "bullets":
                heading(doc, block_title, 3)
                for line in lines:
                    bullet(doc, line)
            else:
                heading(doc, block_title, 3)
                for line in lines:
                    para(doc, line, after=4)
    if rules:
        heading(doc, "Rules and things to watch", 3)
        for rule in rules:
            bullet(doc, rule)
    if audit:
        heading(doc, "What gets recorded", 3)
        para(doc, audit)
    if shot:
        screenshot(doc, shot)


# ---------------------------------------------------------------------------
# Document setup
# ---------------------------------------------------------------------------

doc = Document()
sec = doc.sections[0]
sec.top_margin = sec.bottom_margin = sec.left_margin = sec.right_margin = Inches(1)
sec.header_distance = Inches(0.492); sec.footer_distance = Inches(0.492)

styles = doc.styles
normal = styles["Normal"]
normal.font.name = "Calibri"
normal._element.rPr.rFonts.set(qn("w:ascii"), "Calibri")
normal._element.rPr.rFonts.set(qn("w:hAnsi"), "Calibri")
normal.font.size = Pt(11)
normal.paragraph_format.space_after = Pt(6)
normal.paragraph_format.line_spacing = 1.25

for name, size, color, before, after in [("Heading 1", 16, BLUE, 18, 10),
                                         ("Heading 2", 13, BLUE, 14, 7),
                                         ("Heading 3", 11.5, DARK_BLUE, 10, 4)]:
    s = styles[name]
    s.font.name = "Calibri"
    s._element.rPr.rFonts.set(qn("w:ascii"), "Calibri")
    s._element.rPr.rFonts.set(qn("w:hAnsi"), "Calibri")
    s.font.size = Pt(size)
    s.font.color.rgb = RGBColor.from_string(color)
    s.font.bold = True
    s.paragraph_format.space_before = Pt(before)
    s.paragraph_format.space_after = Pt(after)

for name in ["List Bullet", "List Number"]:
    styles[name].font.name = "Calibri"
    styles[name].font.size = Pt(11)
    styles[name].paragraph_format.space_after = Pt(4)
    styles[name].paragraph_format.line_spacing = 1.25

hdr = sec.header.paragraphs[0]
hdr.alignment = WD_ALIGN_PARAGRAPH.RIGHT
style_para(hdr, after=0, line=1)
set_font(hdr.add_run("GRAC | Control Management - User Manual v3.0"), size=9, color=MUTED)

ftr = sec.footer.paragraphs[0]
ftr.alignment = WD_ALIGN_PARAGRAPH.CENTER
style_para(ftr, after=0, line=1)
set_font(ftr.add_run("Confidential - Internal Use"), size=9, color=MUTED)
# ---------------------------------------------------------------------------
# Cover
# ---------------------------------------------------------------------------

para(doc, "GRAC", bold=True, color=BLUE, size=14, after=44)
para(doc, "CONTROL MANAGEMENT", bold=True, color=NAVY, size=28, after=4)
para(doc, "User Manual", color=DARK_BLUE, size=18, after=10)
para(doc, "Continuous Compliance Assured - the regulatory intelligence repository, obligations, "
          "assurance, maker-checker change management and audit traceability, explained step by step.",
     color=MUTED, size=12, after=30)

table(doc, ["Document", "Details"], [
    ("Title", "GRAC Control Management - User Manual"),
    ("Version", "3.0"),
    ("Module", "Control Management / Repository Management (ControlManagement solution)"),
    ("Written for", "Repository makers, compliance reviewers, checkers/approvers, assurance owners "
                    "and application administrators"),
    ("Prepared by", "GRAC Product Team"),
    ("Date", "September 2026"),
    ("Status", "Released"),
    ("Classification", "Confidential - Internal Use"),
], [2500, 6860])

heading(doc, "Change History", 2)
table(doc, ["Version", "Date", "Summary of Changes"], [
    ("1.0", "28-Jun-2026", "Initial release covering Repository Management, Change Management, "
                           "Access Administration and Audit Traceability."),
    ("2.0", "15-Aug-2026", "Added Obligation Master and the obligation taxonomy, Assurance Management "
                           "metadata masters, SLA Master, event-driven assurance and the upload paths."),
    ("3.0", "08-Sep-2026", "Full rewrite as a step-by-step end-user manual. Every screen in the module "
                           "is documented with its own field table, click-by-click instructions, row "
                           "actions, rules and messages. Adds the shared screen conventions chapter, "
                           "the troubleshooting message index and the glossary."),
], [1000, 1300, 7060])

doc.add_page_break()

heading(doc, "How to use this manual", 1)
para(doc, "The manual is written to be read at the screen. Chapter 3 explains the parts of the "
          "application that behave the same everywhere - the grid, the filters, the 3-dot menu, the "
          "Add/Edit dialog and the approval messages. Read it once; every later chapter assumes it.")
para(doc, "Chapters 4 to 11 take one screen at a time. Each screen chapter follows the same shape:")
bullet(doc, "What this screen is for - one paragraph, plus the menu path.")
bullet(doc, "When to use it - the point in the workflow where you would open it.")
bullet(doc, "Fields on the form - every field, whether it is mandatory, and what to type.")
bullet(doc, "Numbered instructions for Add, Edit, View and Inactive.")
bullet(doc, "Rules and things to watch - the validations that will stop you, in plain language.")
bullet(doc, "What gets recorded - the audit and approval trail the action leaves behind.")
para(doc, "Chapter 14 is a message index: if the application shows you a message you do not expect, "
          "look it up there. Chapter 15 is the glossary.")
para(doc, "Menu paths quoted in this manual are the default navigation. The menu is stored in the "
          "database and can be renamed and regrouped by an administrator (12.3), so your own tree "
          "may read differently - the breadcrumb at the top of each page is the reliable guide.",
     italic=True, color=MUTED, size=10)

callout(doc, "A note on what you can see",
        "The left menu and the buttons on each screen are driven by your role. If a screen or an "
        "Add / Edit / Inactive / Approve button described in this manual is not on your screen, your "
        "role does not carry that permission - ask your administrator rather than assuming the feature "
        "is missing.")

doc.add_page_break()

heading(doc, "Table of Contents", 1)
toc_field(doc)
para(doc, "Right-click the table above and choose 'Update Field' to populate it.",
     italic=True, color=MUTED, size=10)
para(doc, "Tip: in Microsoft Word press Ctrl+A then F9 to refresh the contents and page numbers.",
     italic=True, color=MUTED, size=10)
doc.add_page_break()


# ---------------------------------------------------------------------------
# 1. Introduction
# ---------------------------------------------------------------------------

heading(doc, "1. Introduction", 1)

heading(doc, "1.1 What the module does", 2)
para(doc, "Control Management is the part of GRAC that holds the organisation's regulatory intelligence "
          "and keeps it current. It answers four questions, and everything in the module exists to "
          "answer one of them:")
bullet(doc, "What are we required to do? - captured as Authorities, Artifacts, Releases, Source "
            "Structure and Source Statements: the regulator's own words, in the regulator's own "
            "structure, version by version.")
bullet(doc, "How do we satisfy it? - captured as Practices and Obligations, and the mappings that tie "
            "them back to the exact statement they answer.")
bullet(doc, "How do we prove it? - captured as evidence specifications, assurance metadata, SLAs, and "
            "the event checklists raised each time a tracked event occurs.")
bullet(doc, "Who changed what, and who approved it? - captured by maker-checker change management and "
            "an append-only audit trail.")

heading(doc, "1.2 Who this manual is for", 2)
table(doc, ["Role", "What you will spend your time doing"], [
    ("Repository maker",
     "Onboarding authorities, artifacts and releases; capturing source structure and statements; "
     "authoring practices and obligations; building mappings. Your saves usually go out as change "
     "requests for a checker to approve."),
    ("Checker / approver",
     "Reviewing pending change requests on the Change Management screen, comparing old against "
     "proposed values, then approving, rejecting or sending back with comments."),
    ("Assurance owner / operator",
     "Configuring assurance metadata and SLAs, raising events, and completing the checklists those "
     "events generate."),
    ("Administrator",
     "Users, roles, the menu tree, the role-permission matrix and the approval workflow configuration."),
    ("Auditor / reviewer",
     "Reading the Audit Traceability and Version History screens; both are read-only by design."),
], [2200, 7160])

heading(doc, "1.3 How the pieces fit together", 2)
para(doc, "The repository is a chain. Each level is created inside the one above it, so records are "
          "normally captured top-down:")
step(doc, "Authority - the body that issues the rules (a regulator, a standards body, an internal "
          "policy owner).")
step(doc, "Artifact - a regulation, standard, law, directive or programme published by that authority.")
step(doc, "Release - a dated, numbered version of that artifact. Everything version-specific hangs off "
          "a release, which is what lets you keep last year's wording alongside this year's.")
step(doc, "Source Structure - the artifact's own hierarchy for that release: chapters, sections, "
          "clauses. Structure nodes are folders; they carry no regulatory text themselves.")
step(doc, "Source Statement - the actual regulatory sentence, captured under a structure node.")
step(doc, "Practice - an atomic, assessable thing your organisation does. Practices are global: one "
          "practice can answer statements in many artifacts and many releases.")
step(doc, "Obligation - what a practice must actually deliver, of a specific type, with its evidence "
          "specification.")
step(doc, "Mappings - Practice to Statement, and Obligation to Practice/Release, which is what makes "
          "traceability from a regulator's sentence to your evidence possible in both directions.")

callout(doc, "Why the order matters",
        "Dropdowns are fed from the repository, not typed by hand. You cannot pick an Artifact until "
        "its Authority exists, or a Release until its Artifact exists. If a dropdown looks empty, the "
        "record one level up has not been created yet - or it has been made inactive.")

heading(doc, "1.4 Two ways to get data in", 2)
para(doc, "Every screen supports record-by-record entry through its form. For a first load, or for "
          "anything larger than a handful of rows, use the upload paths instead:")
bullet(doc, "Bulk Excel Upload (chapter 9) - one workbook, one sheet per business table, loaded in a "
            "single all-or-nothing transaction. Use it to onboard a whole artifact from scratch.")
bullet(doc, "Single-Form Excel Upload (chapter 10) - one form at a time, scoped to one release, with a "
            "signed template. Use it to top up an existing release.")
para(doc, "Both paths validate before they write, and neither touches the database until validation "
          "passes and you press Commit.")

doc.add_page_break()


# ---------------------------------------------------------------------------
# 2. Getting started
# ---------------------------------------------------------------------------

heading(doc, "2. Getting started", 1)

heading(doc, "2.1 Signing in", 2)
para(doc, "Open the application URL supplied by your administrator. The sign-in page shows the GRAC "
          "logo on the left and the form on the right.")
step(doc, "In Login ID or Email, type either your login ID or the email address on your account - "
          "the system accepts both.")
step(doc, "Type your password.")
step(doc, "Click Sign In.")
para(doc, "On success you land on the Repository Management dashboard. On failure the page reloads "
          "with the message 'Invalid Login ID / Email or Password.' above the form. The identifier you "
          "typed is kept so you only have to retype the password.")

callout(doc, "Repeated failures",
        "Sign-in attempts are rate limited. If you get the invalid-credentials message several times "
        "in quick succession, wait a moment before trying again rather than retrying immediately - and "
        "use Forgot Password rather than guessing.", WARN_FILL)

heading(doc, "2.2 Setting your password on first sign-in", 2)
para(doc, "When an administrator creates your account it carries a default password, and the account "
          "is flagged so that password cannot be kept. The first time you sign in you are taken "
          "straight to a page headed 'Set Your Password' - you cannot reach any other screen until you "
          "finish it.")
step(doc, "Default / Current Password - type the default password your administrator gave you.")
step(doc, "New Password - choose a new one. It must be at least 8 characters; the field will not "
          "accept fewer.")
step(doc, "Confirm New Password - retype it exactly. If the two do not match you will see 'Password "
          "and confirmation do not match.'")
step(doc, "Click Update Password. You are returned to the application, signed in.")

heading(doc, "2.3 Changing your password later", 2)
para(doc, "The same page is available at any time from the Change Password link. It is headed 'Change "
          "Password' rather than 'Set Your Password' and works identically: current password, new "
          "password (8 characters minimum), confirmation, Update Password.")

heading(doc, "2.4 Forgot password", 2)
para(doc, "Click Forgot Password? beside the password box on the sign-in page.")
step(doc, "Type your Login ID or Email.")
step(doc, "Click Request Reset.")
step(doc, "The page confirms: 'If an active account exists for that Login ID or Email, your "
          "administrator has been notified to reset the password.' The wording is deliberately "
          "non-committal - it does not reveal whether the account exists.")
step(doc, "Your administrator runs Reset Password against your row on the User Management screen. That "
          "puts the account back on the default password and re-arms the first-login flow.")
step(doc, "Sign in with the default password. You are sent straight to Set Your Password, as in 2.2.")

callout(doc, "No email is sent yet",
        "Password reset is an administrator action inside the application, not an automated email. "
        "After requesting a reset, contact your administrator so they know to run it.", WARN_FILL)

heading(doc, "2.5 The parts of the screen", 2)
table(doc, ["Area", "What it holds"], [
    ("Left menu", "The navigation tree, built from the database and filtered by your role. Parent items "
                  "expand and collapse; the branch containing the screen you are on stays open and the "
                  "current item is highlighted."),
    ("Top bar", "The user menu at the right end. Open it to Sign Out."),
    ("Page heading", "The breadcrumb line ('Repository Management / Authority' or 'Assurance "
                     "Management / ...'), the screen title, a one-line description, and the Add button "
                     "when your role may add."),
    ("Toolbar", "Search box, the cascading filters that apply to this screen, the status filter, Clear "
                "filters and Refresh."),
    ("Grid", "The records, a fixed number of rows at a time, with a 3-dot Actions menu at the end of "
             "every row."),
    ("Pager", "Below the grid: rows-per-page selector and page navigation."),
], [1800, 7560])

heading(doc, "2.6 The dashboard", 2)
para(doc, "Signing in without choosing a menu item lands you on the Repository Management dashboard. "
          "It shows summary tiles and a card for every repository area your role can see. Clicking a "
          "card is the same as clicking that item in the left menu. The 'Start onboarding' button "
          "takes you to the Authority screen, which is where a new artifact chain begins.")

heading(doc, "2.7 Signing out", 2)
step(doc, "Click the user menu at the right of the top bar.")
step(doc, "Click Sign Out. Your session is cleared and you are returned to the sign-in page.")
callout(doc, "Sessions expire",
        "If you leave the application idle for a long time your session ends, and the next action "
        "returns you to the sign-in page. Anything typed into an open dialog is lost, so save work in "
        "progress before stepping away.")

doc.add_page_break()
# ---------------------------------------------------------------------------
# 3. How every screen works
# ---------------------------------------------------------------------------

heading(doc, "3. How every screen works", 1)
para(doc, "Almost every screen in the module is the same screen with different columns. Learn it once "
          "here and the rest of the manual is mostly a list of fields.")

heading(doc, "3.1 The grid", 2)
para(doc, "The grid shows a fixed number of rows so the page never grows with the record count - "
          "everything beyond the visible page is reached through the pager underneath. Statuses are "
          "shown as coloured badges so you can see at a glance which rows are live:")
table(doc, ["Badge", "Meaning"], [
    ("Plain", "Active, or any status that needs no attention."),
    ("Muted / grey", "Inactive, Retired, Archived, Rejected or Cancelled - the record is no longer in "
                     "play but its history is intact."),
    ("Amber / pending", "Pending Approval, Draft, Review, In Review or Sent Back - the record is "
                        "mid-workflow and is waiting on somebody."),
], [1800, 7560])

heading(doc, "3.2 Searching and filtering", 2)
step(doc, "Search - type into the Search box at the left of the toolbar. It filters the rows already "
          "loaded for the screen.")
step(doc, "Cascading filters - screens that sit inside the repository chain show Authority, Artifact "
          "and Release dropdowns as appropriate. They cascade: choosing an authority narrows the "
          "artifact list, and choosing an artifact narrows the release list.")
step(doc, "Status - every screen except the two immutable logs offers a status filter. The values "
          "offered are the ones that screen can actually hold (see 3.6), not a generic list.")
step(doc, "Clear filters - the funnel icon resets Search, every dropdown and the status filter in one "
          "click.")
step(doc, "Refresh - the circular arrow re-fetches the rows from the server. Use it after somebody "
          "else has approved a change you are waiting on.")
callout(doc, "A filter is a convenience, not a prerequisite",
        "On most screens you no longer have to set a filter before you can press Add - the form asks "
        "for the release or the parent itself. The filters are there to help you find rows, not to "
        "gate data entry.")

heading(doc, "3.3 Paging", 2)
para(doc, "The pager below the grid shows which rows you are looking at out of the total, lets you "
          "step through pages, and lets you change the rows per page. The default is 10; the other "
          "choices are 25, 50 and 100. On the tree-shaped screens the page size counts top-level rows "
          "- the children of a visible parent always come with it, so a tree is never cut in half.")

heading(doc, "3.4 The 3-dot Actions menu", 2)
para(doc, "Every row ends with a vertical 3-dot button. Clicking it opens the actions available to you "
          "on that row - the menu is built from your permissions and from the row's own status, so two "
          "rows on the same grid can offer different actions.")
table(doc, ["Action", "When it appears", "What it does"], [
    ("View", "Always", "Opens the record read-only."),
    ("Edit", "You hold Edit on this screen", "Opens the record for change."),
    ("Inactive", "You hold Delete/Inactive rights and the row is currently active",
     "Deactivates the record after a confirmation. Nothing is erased."),
    ("Activate", "You hold Delete/Inactive rights and the row is currently inactive or retired",
     "Puts the record back to Active, along with anything its deactivation took down."),
    ("Approve / Reject / Send Back", "Change Management, and you hold the matching permission",
     "The checker decisions - see chapter 11."),
    ("Screen-specific actions", "Varies", "Shortcuts such as Add Artifact on an Authority row, or Add "
                                          "Child Node on a structure node. Listed in each chapter."),
], [2100, 3000, 4260])

heading(doc, "3.5 The Add / Edit / View dialog", 2)
para(doc, "Most screens capture their record in a dialog rather than a separate page. The dialog "
          "header carries the title and, in view mode, a 'View Mode' chip and an Edit button. The "
          "footer carries Cancel / Back and Save.")
bullet(doc, "A red asterisk (*) marks a mandatory field. Save is refused until every one is filled, "
            "and the first offending field is highlighted with the reason underneath.")
bullet(doc, "Long-form text (descriptions, statement text, objectives) sits across the full width of "
            "the dialog rather than in a narrow column.")
bullet(doc, "Keyword fields are tag inputs: type a keyword and press comma or Enter to turn it into a "
            "chip; click the x on a chip to remove it.")
bullet(doc, "Multi-select fields (Roles, Industries, Practices) let you tick several values at once; "
            "the larger ones carry their own search box.")
bullet(doc, "You never type JSON. Any structured value is captured through proper controls.")

heading(doc, "3.6 Status vocabulary", 2)
para(doc, "Different families of screen use different status words, deliberately - a user is "
          "deactivated, a regulation is retired. The status dropdown on each screen offers only the "
          "words that screen can hold.")
table(doc, ["Screens", "Values offered"], [
    ("Authority, Artifact, Source Structure, Source Classification, Source Statement, Practice, "
     "Obligation, all mappings, SLA Master and all Assurance masters", "Active / Retired"),
    ("User, Role, Menu, Role Permissions, Approval Workflow", "Active / Inactive"),
    ("Release", "Draft / Active / Retired"),
    ("Change Management", "Pending Approval / Approved / Auto Approved / Rejected / Sent Back"),
    ("Audit Traceability, Version History", "No status filter - these are immutable logs"),
], [4600, 4760])

heading(doc, "3.7 What happens when you press Save", 2)
para(doc, "Saving does not always write straight to the live record. Modules covered by an approval "
          "workflow route the change through maker-checker first. You will see one of two messages:")
table(doc, ["Message", "What it means", "What to do next"], [
    ("Change submitted for approval. The main record will update after checker approval.",
     "Your change was parked as a change request. The live record is unchanged and the request shows "
     "as Pending Approval on the Change Management screen.",
     "Tell your checker, or wait. You can watch the request on Change Management."),
    ("Change saved and auto-approved.",
     "Approval is not required for this module (or your role is allowed to self-approve), so the "
     "change was applied immediately.",
     "Nothing - the record is live. The action is still in the audit trail."),
], [2900, 3400, 3060])
para(doc, "Deactivating and reactivating go through the same gate: on a maker-checker module, "
          "Inactive and Activate raise change requests rather than flipping the status on the spot.")

heading(doc, "3.8 Tree-shaped screens", 2)
para(doc, "Source Structure, Source Statements, Obligation Master, Practices - Obligation Mapping and "
          "Audit Traceability show a tree rather than a flat list. Parent rows carry a chevron; click "
          "it to expand or collapse. Inactive branches are shown in a muted style so a retired node is "
          "obvious without opening it.")

heading(doc, "3.9 Full-page forms", 2)
para(doc, "Five screens are too big for a dialog and open as their own page with a fixed action bar at "
          "the bottom: Source Statement, Obligation Master, Practices - Obligation Mapping, SLA Master "
          "and the event screens. On these, Cancel / Back returns you to the grid you came from and "
          "discards anything unsaved.")

doc.add_page_break()


# ---------------------------------------------------------------------------
# 4. Repository foundation
# ---------------------------------------------------------------------------

heading(doc, "4. Repository foundation - Authority, Artifact, Release", 1)
para(doc, "These three screens create the spine that everything else hangs from. Work through them in "
          "order the first time you onboard a new source of regulation.")

screen_section(
    doc, "4.1", "Authority", "Repository Management > Authority",
    purpose="An Authority is the body that issues or supervises the rules - a regulator such as RBI or "
            "SEBI, a standards body such as ISO or PCI SSC, or an internal policy owner. It is the "
            "top of the repository chain: nothing else can be created until at least one authority "
            "exists.",
    when="When a new regulator, standards body or internal policy owner comes into scope for the "
         "organisation. You will typically create an authority once and then never touch it again.",
    fields=[
        ("Code", "Yes", "A short unique code you will recognise in dropdowns and reports - RBI, SEBI, "
                        "ISO, NIST. Keep it short and stable; it appears everywhere."),
        ("Name", "Yes", "The full display name, e.g. 'Reserve Bank of India'."),
        ("Description", "No", "Free text - what this body governs, and why it is in scope for you."),
        ("Jurisdiction", "No", "Pick from the jurisdiction list, e.g. India, EU, Global."),
        ("Website", "No", "The authority's official site. Must be a valid URL if entered."),
        ("Status", "Yes", "Active or Retired. Defaults to Active."),
    ],
    row_actions=[
        ("Add Artifact", "Opens the Artifact form with this authority already selected. The quickest "
                         "way to start onboarding a regulation you have just created the body for."),
    ],
    rules=[
        "Code must be unique across all authorities. Saving a duplicate is rejected with a message "
        "naming the clash.",
        "Retiring an authority does not delete its artifacts, releases or statements - they remain "
        "readable and auditable. It stops the authority being offered when creating new records.",
        "If you cannot find an authority in a dropdown elsewhere, check the status filter here: it has "
        "probably been retired.",
    ],
    shot="Authority grid with the toolbar filters and the 3-dot Actions menu open on a row.",
)

screen_section(
    doc, "4.2", "Artifacts", "Repository Management > Artifacts",
    purpose="An Artifact is a single document published by an authority - a regulation, standard, law, "
            "directive, circular or programme. The artifact is the thing; its versions are Releases.",
    when="When the authority publishes something you must comply with, or when you bring an existing "
         "standard into the repository for the first time.",
    fields=[
        ("Authority", "Yes", "Pick the issuing body. Pre-filled if you arrived here via Add Artifact "
                             "from an Authority row."),
        ("Code", "Yes", "Unique short code for the artifact, e.g. ISO27001, PCI-DSS, RBI-CSF."),
        ("Name", "Yes", "The full published title."),
        ("Description", "No", "Scope and applicability in your own words."),
        ("Category", "Yes", "Pick from the category list - regulation, standard, law, directive, "
                            "programme and so on."),
        ("Industries", "No", "Tick every industry this applies to. Multi-select."),
        ("Jurisdictions", "No", "Tick every jurisdiction this applies in. Multi-select."),
        ("Status", "Yes", "Active or Retired."),
    ],
    row_actions=[
        ("Add Release", "Opens the Release form with this artifact already selected - the natural next "
                        "step after creating an artifact."),
    ],
    rules=[
        "Code must be unique across all artifacts, not just within the authority.",
        "Industries and Jurisdictions are what applicability rules read later. Leaving them blank does "
        "not break anything, but it makes automatic scoping impossible.",
        "You cannot capture structure or statements against an artifact directly - create a Release "
        "first. Everything version-specific belongs to a release.",
    ],
    shot="Artifact form showing the Authority dropdown and the multi-select Industries control.",
)

screen_section(
    doc, "4.3", "Releases", "Repository Management > Releases",
    purpose="A Release is a dated, numbered version of an artifact. It is the single most important "
            "record in the repository, because source structure, statements, classifications and "
            "mappings all belong to a release rather than to the artifact. That is what lets the "
            "2022 edition and the 2013 edition of the same standard coexist without colliding.",
    when="Whenever the authority publishes a new version, amendment or revision - and once at the "
         "start, for the version you are onboarding.",
    fields=[
        ("Artifact", "Yes", "The artifact this version belongs to."),
        ("Version", "Yes", "The version identifier as published, e.g. '2022', 'v4.0', "
                           "'Rev 3'. Combined with the artifact it must be unique."),
        ("Effective Date", "No", "The date the version takes effect. Leave blank while it is still "
                                 "in draft."),
        ("End Date", "No", "The date it stops applying. Leave blank while it is open-ended."),
        ("Release Notes", "No", "What changed in this version - the summary a reviewer reads first."),
        ("Status", "Yes", "Draft, Active or Retired. Draft is a real pre-effective state: use it while "
                          "you are still loading content."),
    ],
    row_actions=[
        ("Add Source Structure", "Opens the Source Structure form with this release locked in, ready "
                                 "to capture the first node."),
        ("Add Source Classification", "Opens the Source Classification form for this release."),
    ],
    rules=[
        "Artifact plus Version must be unique. A second '2022' under the same artifact is rejected.",
        "Keep a release in Draft while you load its structure and statements, then move it to Active "
        "when the content is complete and reviewed.",
        "The Single-Form Upload screen only offers Draft and Active releases - a retired release "
        "cannot be topped up.",
        "Retiring a release does not remove its statements or mappings. Historical traceability is the "
        "reason the module keeps them.",
    ],
    shot="Release grid filtered by authority and artifact, showing Draft and Active rows side by side.",
)

doc.add_page_break()
# ---------------------------------------------------------------------------
# 5. Capturing the source
# ---------------------------------------------------------------------------

heading(doc, "5. Capturing the source text", 1)
para(doc, "These three screens hold the regulator's own words, in the regulator's own structure. "
          "Nothing here is your interpretation - that comes later, as Practices and Obligations.")

screen_section(
    doc, "5.1", "Source Classification", "Repository Management > Source Classification",
    purpose="A Source Classification is a category or level that a release uses to label its own "
            "statements - 'Mandatory' versus 'Recommended', 'Level 1 / 2 / 3', 'Basic / Advanced'. "
            "Classifications are defined per release, because different versions of the same standard "
            "often relabel their tiers.",
    when="Immediately after creating a release, and before capturing statements - so the "
         "classification is available on the statement form.",
    fields=[
        ("Release", "Yes", "The release these classifications belong to."),
        ("Classification Scheme", "No", "The name of the scheme the categories come from, e.g. "
                                        "'Applicability', 'Maturity Level'. Group related "
                                        "classifications under a common scheme name."),
        ("Classification Name", "Yes", "The category itself, e.g. 'Mandatory', 'Level 2'."),
        ("Description", "No", "What the classification means in this release, in the release's own "
                              "terms."),
    ],
    rules=[
        "Classifications are scoped to one release. Creating them once does not make them available to "
        "the next version - recreate them, or load them with the release.",
        "Classification is optional on a statement. Leave it blank if the release does not tier its "
        "requirements.",
    ],
    shot="Source Classification grid filtered to one release.",
)

screen_section(
    doc, "5.2", "Source Structure", "Repository Management > Source Structure",
    purpose="Source Structure is the artifact's native hierarchy for one release - its parts, "
            "chapters, sections and clauses. Structure nodes are folders: they organise, they do not "
            "carry the regulatory text. The text lives in Source Statements underneath them.",
    when="After creating a release, to reproduce the document's own table of contents before you "
         "capture any wording.",
    fields=[
        ("Release", "Yes", "The release this node belongs to. Locked (read-only) when you arrive via "
                           "Add Child Node, or when editing or viewing an existing node - a node "
                           "cannot be moved to another release."),
        ("Node Type", "Yes", "What kind of node this is - Chapter, Section, Clause, Annex and so on. "
                             "Pick from the list."),
        ("Node Reference", "Yes", "The reference the document itself uses, e.g. 'A.5', '4.2.1', "
                                  "'Chapter III'. Must be unique inside the release."),
        ("Node Title", "Yes", "The heading as printed, e.g. 'Organisational Controls'."),
        ("Description", "No", "Any preamble or scope note attached to the node."),
        ("Status", "Yes", "Active or Retired."),
    ],
    row_actions=[
        ("Add Child Node", "Creates a node one level down, with this node as its parent and the "
                           "release locked. This is how you build depth - always add children from "
                           "the parent row rather than trying to set a parent on a blank form."),
        ("Add Source Statement", "Jumps straight to the Source Statement page with this node "
                                 "pre-selected. Use it as soon as a node is a leaf that carries text."),
    ],
    rules=[
        "Node Reference must be unique within the release. The same reference may of course appear "
        "again in a different release of the same artifact.",
        "Build top-down: create the root nodes first, then use Add Child Node on each. A child cannot "
        "be created before its parent exists.",
        "Retiring a parent node takes its branch out of play. Reactivating the parent restores what "
        "its deactivation took down.",
        "Do not put regulatory wording in the Description field. If it is text the regulator wrote as "
        "a requirement, it belongs in a Source Statement.",
    ],
    shot="Source Structure tree grid with a chapter expanded to show its sections.",
)

heading(doc, "5.3 Source Statements", 2)
heading(doc, "What this screen is for", 3)
para(doc, "A Source Statement is the actual regulatory sentence - the requirement as written, captured "
          "verbatim under the structure node it belongs to. This is the record every mapping and every "
          "traceability report ultimately points at, so accuracy here matters more than anywhere else "
          "in the module.")
para(doc, "Menu path: Repository Management > Source Statements", italic=True, color=MUTED, size=10)

heading(doc, "When to use it", 3)
para(doc, "After the release's source structure exists. Work node by node: open a leaf node, capture "
          "every statement under it, move to the next.")

callout(doc, "This one opens as a full page",
        "Source Statement is not a dialog. Add and Edit open their own page with Cancel / Back and "
        "Save in a bar fixed to the bottom of the window, because the source-structure picker needs "
        "the room.")

heading(doc, "Fields on the form", 3)
table(doc, FIELD_HEADERS, [
    ("Release", "Yes", "Which release the statement belongs to. Set from the grid filter or from the "
                       "node you came from, and shown as context on the form."),
    ("Source Structure Node", "Yes", "Pick the node in the tree. The picker shows the release's "
                                     "hierarchy; click the node the statement sits under. "
                                     "Pre-selected if you arrived via Add Source Statement."),
    ("Statement Classification", "No", "One of the classifications defined for this release "
                                       "(see 5.1). Leave blank if the release does not tier."),
    ("Statement Reference", "Yes", "The clause number the document gives this statement, e.g. "
                                   "'A.5.1.1'. Must be unique inside the release."),
    ("Statement Title", "No", "A short heading for the statement."),
    ("Statement Text", "Yes", "The regulatory wording itself. Capture it as published - do not "
                              "paraphrase, summarise or reword."),
    ("Display Order", "No", "Controls the order statements appear in under the same node. "
                            "Edit/View only - it is not asked on Add."),
    ("Status", "Yes", "Active or Retired. Edit/View only - a new statement is created Active."),
    ("Remarks", "No", "Your own notes about the statement - ambiguities, interpretation questions, "
                      "links to guidance. Never regulatory text."),
], FIELD_WIDTHS)

heading(doc, "Capture a statement", 3)
step(doc, "Open Source Statements from the menu, or use Add Source Statement on a Source Structure "
          "row to skip the node picking.")
step(doc, "Click Add. The full-page form opens.")
step(doc, "In the Source Structure Node tree, click the node the statement belongs under.")
step(doc, "Choose a Statement Classification if the release uses them.")
step(doc, "Type the Statement Reference exactly as the document numbers it.")
step(doc, "Paste the regulatory wording into Statement Text, unchanged.")
step(doc, "Add a Statement Title and Remarks if they help a later reviewer.")
step(doc, "Click Save in the bottom bar. Cancel / Back discards everything and returns you to the grid.")

heading(doc, "Edit, view and retire", 3)
para(doc, "Use the 3-dot menu on the row: Edit opens the same page pre-filled and adds the Display "
          "Order and Status fields; View opens it read-only; Inactive retires the statement after a "
          "confirmation. Mappings already made against a retired statement survive - traceability is "
          "never rewritten by a status change.")

heading(doc, "Extra action on the 3-dot menu", 3)
table(doc, ["Action", "What it does"], [
    ("Map Controls", "Opens the mapping view for this statement so you can attach practices to it "
                     "without going to the mapping screen and searching for it. Requires Edit rights."),
], [2600, 6760])

heading(doc, "Rules and things to watch", 3)
bullet(doc, "Statement Reference must be unique within the release. A duplicate is rejected on save.")
bullet(doc, "You cannot attach a statement to a release without choosing a node - the node is what "
            "gives it its place in the hierarchy.")
bullet(doc, "Statement Text is mandatory and is the whole point of the record. A statement with a "
            "reference and no text is a structure node in disguise; create it as a node instead.")
bullet(doc, "Statement Type is no longer collected on this form. Classification is the governed field "
            "and replaces it; values loaded by older bulk uploads are retained in the database.")

heading(doc, "What gets recorded", 3)
para(doc, AUDIT_STD)
screenshot(doc, "Source Statement full-page form: the node tree on the left, statement fields on the "
                "right, action bar fixed at the bottom.")

doc.add_page_break()


# ---------------------------------------------------------------------------
# 6. Practices and Obligations
# ---------------------------------------------------------------------------

heading(doc, "6. Practices and Obligations", 1)
para(doc, "This is where the regulator's words become your organisation's work. A Practice is "
          "something you do; an Obligation is what that practice must deliver, in a form precise "
          "enough to test.")

screen_section(
    doc, "6.1", "Practices", "Repository Management > Practices",
    purpose="A Practice is an atomic, assessable thing the organisation does - 'Quarterly privileged "
            "access review', 'Vendor due diligence before onboarding'. Practices are global: one "
            "practice can answer statements across many artifacts, authorities and releases, which is "
            "exactly what stops you writing the same control five times for five overlapping "
            "regulations.",
    when="Once the source statements are captured and you know what the organisation actually has to "
         "do. Check whether a suitable practice already exists before creating a new one.",
    fields=[
        ("Practice Code", "Auto", "Generated by the system on save as PR-001, PR-002 and so on. The "
                                  "field is not shown when adding, and is read-only on edit and view."),
        ("Practice Name", "Yes", "A short action-shaped name. Name the activity, not the regulation "
                                 "it satisfies - the mapping records that."),
        ("Description", "Yes", "What the practice is, in full. This is the definitive statement of the "
                               "practice and what a reviewer reads."),
        ("Objective", "No", "What outcome the practice exists to achieve."),
        ("Keywords", "No", "Comma-separated tags used for search and for spotting near-duplicates, "
                           "e.g. 'access review, KYC, vendor due diligence'. Type a word and press "
                           "comma or Enter to turn it into a chip."),
        ("Status", "Yes", "Active or Retired."),
    ],
    rules=[
        "Do not invent your own Practice Code - the save procedure assigns it. Anything typed into "
        "the field on edit is ignored.",
        "Write practices so they are reusable. A practice named after one clause of one regulation "
        "cannot be mapped to the equivalent clause in another framework.",
        "Description is mandatory. A practice with only a name cannot be assessed.",
        "Retiring a practice leaves its existing mappings intact but stops it being offered for new "
        "ones.",
    ],
    shot="Practices grid with the keyword chips visible in the Add dialog.",
)

heading(doc, "6.2 Obligation Master", 2)
heading(doc, "What this screen is for", 3)
para(doc, "An Obligation is what a practice must actually deliver - stated precisely enough that "
          "somebody can test whether it happened. The Obligation Master is where you write one, "
          "choose its type, fill in the detail that type requires, list the evidence it produces, and "
          "point it at the source statements it was written against. All of that is captured on one "
          "page and saved as a single approval bundle.")
para(doc, "Menu path: Repository Management > Obligation Master", italic=True, color=MUTED, size=10)

heading(doc, "When to use it", 3)
para(doc, "After the practice exists and you know what it must produce. One practice usually carries "
          "several obligations of different types.")

heading(doc, "Section 1 - Obligation", 3)
table(doc, FIELD_HEADERS, [
    ("Obligation Name", "Yes", "The display key for this obligation, up to 500 characters. Keep it "
                               "unique - the mapping and evidence screens resolve obligations by name "
                               "and will refuse an ambiguous one."),
    ("Obligation Type", "Yes", "One of the seven types below. Choosing a type reveals the typed detail "
                               "panel underneath, and a short description of the type appears beside "
                               "the dropdown."),
    ("Status", "Yes", "Active or Retired."),
    ("Keywords", "No", "Comma-separated tags. As you type, a warning-only panel appears listing "
                       "similar existing obligations so you can spot a duplicate before creating one. "
                       "It never blocks Save."),
    ("Obligation Description", "No", "What the obligation requires, in full - a few sentences rather "
                                     "than a phrase."),
], FIELD_WIDTHS)

heading(doc, "Section 2 - the typed detail panel", 3)
para(doc, "The panel below the master fields is driven entirely by the Obligation Type you chose. It "
          "is shown on its own tinted surface so the boundary is obvious: everything inside it belongs "
          "to the type, and is replaced wholesale if you change the type.")
table(doc, ["Obligation Type", "What it captures", "Its fields"], [
    ("State", "A positive parametric assertion - something that must be true.",
     "Attribute (required, e.g. password.length), Operator (required, e.g. >=), Value (required, "
     "e.g. 12), Unit, Tolerance."),
    ("Execution", "What must be done, and when.",
     "Action (required), Execution Frequency, Due Within (e.g. '30 days', 'quarter-end')."),
    ("Assurance", "What must be verified, and what triggers the verification.",
     "Verification Method (required), Trigger Mode (required), then either Assurance Frequency "
     "(Scheduled) or Event Domain + Event + Due Within days (Event driven)."),
    ("Event Response", "If X happens, do Y within an SLA.",
     "Trigger Event (required), Response Action (required), SLA Value, SLA Unit "
     "(Hours/Days/Weeks/Months/Years)."),
    ("Constraint", "A prohibition - what must never be true.",
     "Prohibited Condition (required). A prohibition is the condition, so this type has a single "
     "field by design."),
    ("Retention", "What must be preserved, and for how long.",
     "Retained Object (required, e.g. audit_log), Min Retention Value, Min Retention Unit, "
     "Max Retention Value, Max Retention Unit, Disposal Policy. Units are Days, Weeks, "
     "Months or Years."),
    ("Evidence", "A standalone evidence obligation.",
     "No typed fields. The panel says so; describe the proof in Evidence Details instead."),
], [1500, 3200, 4660])

callout(doc, "Changing the type discards the detail",
        "If you change Obligation Type after filling in the typed panel, a confirmation appears: "
        "'Change Obligation Type?'. Accepting it clears everything you entered in that panel, because "
        "the new type asks different questions. Cancel keeps the current type and your entries.",
        WARN_FILL)

heading(doc, "The Assurance trigger cascade", 3)
para(doc, "Assurance is the only type with a branch, and it is worth understanding because it is what "
          "creates event checklists later:")
step(doc, "Set Trigger Mode to Scheduled if the verification runs on a calendar. You are then asked "
          "for an Assurance Frequency, and nothing else.")
step(doc, "Set Trigger Mode to Event driven if the verification must run every time something happens. "
          "You are then asked for an Event Domain, then the Event within that domain, then Due Within "
          "(days).")
step(doc, "Due Within is an interval, not a date. It is applied to each occurrence: an event on the "
          "3rd with Due Within 7 produces a checklist item due on the 10th.")
step(doc, "Leave Due Within blank if the item has no deadline.")
callout(doc, "This is the link to Event Checklists",
        "Every Event-driven Assurance obligation you configure here becomes a line on the checklist "
        "raised whenever that event is recorded (chapter 7). If a raised event produces an empty "
        "checklist, it is because no assurance obligation names that event.")

heading(doc, "Section 3 - Evidence Details", 3)
para(doc, "One row per evidence type this obligation produces. Click Add Evidence to add a row; each "
          "row carries:")
table(doc, ["Column", "What to enter"], [
    ("Evidence Type", "Pick from the evidence type master - the kind of proof produced (report, "
                      "screenshot, signed approval, log extract)."),
    ("Retention Period", "How long this specific piece of evidence must be kept. Retention is stated "
                         "per evidence row, not once for the whole obligation."),
    ("Remarks", "Anything a collector or reviewer needs to know about this evidence."),
], [2600, 6760])
para(doc, "Use the delete control at the end of a row to remove it. An obligation may legitimately "
          "have no evidence rows while it is being drafted.")

heading(doc, "Section 4 - Source Statement Mapping", 3)
para(doc, "The tree at the bottom of the page is Release > Source Structure > Framework Statements. "
          "Structure nodes act as folders; tick the statements this obligation was written against. "
          "A counter above the tree shows how many are selected, and the search box filters both node "
          "titles and statement text.")
callout(doc, "What this mapping controls",
        "It narrows the obligation picker on the Practices - Obligation Mapping screen. A matrix row "
        "for Release R offers the obligations mapped to a statement of Release R, plus every "
        "obligation that has mapped no statements at all. So leaving this section empty makes the "
        "obligation available on every release - which is sometimes exactly what you want.")

heading(doc, "Create an obligation", 3)
step(doc, "Open Obligation Master and click Add. The full-page form opens.")
step(doc, "Type the Obligation Name and pick the Obligation Type.")
step(doc, "Fill the typed detail panel that appears. Required fields inside it carry the same red "
          "asterisk.")
step(doc, "Add keywords, and glance at the similar-obligations panel if it appears.")
step(doc, "Write the Obligation Description.")
step(doc, "Click Add Evidence for each piece of proof the obligation produces and complete the row.")
step(doc, "In Source Statement Mapping, tick the statements this obligation answers - or leave it "
          "empty deliberately.")
step(doc, "Click Save Obligation in the bottom bar. The master, the typed detail, the evidence rows "
          "and the statement mappings are saved together as one change.")

heading(doc, "Rules and things to watch", 3)
bullet(doc, "Obligation Name should be unique across the database. Duplicated names make the mapping "
            "and bulk-upload screens reject rows as ambiguous.")
bullet(doc, "Execution Frequency and Retention Period are not master fields. Execution cadence belongs "
            "to the Execution typed panel; retention is stated per evidence row. Values saved by "
            "older versions are preserved and still round-trip.")
bullet(doc, "The similar-obligations panel is advisory only. It warns; it never blocks.")
bullet(doc, "Save is all-or-nothing. If the typed panel has an unfilled required field, nothing is "
            "saved - not the evidence rows either.")

heading(doc, "What gets recorded", 3)
para(doc, AUDIT_STD)
screenshot(doc, "Obligation Master page with type set to Assurance, the trigger cascade showing Event "
                "Domain and Event, and two evidence rows.")

doc.add_page_break()
# ---------------------------------------------------------------------------
# 6.3 / 6.4 Mappings
# ---------------------------------------------------------------------------

heading(doc, "6.3 Practices - Statement Mapping", 2)
heading(doc, "What this screen is for", 3)
para(doc, "This is the traceability link that matters most: it says which of your practices answer "
          "which of the regulator's statements. Once it exists you can ask both questions - 'what do "
          "we do about clause A.5.1.1?' and 'which clauses would break if we stopped doing PR-014?'")
para(doc, "Menu path: Repository Management > Practices - Statement Mapping",
     italic=True, color=MUTED, size=10)

heading(doc, "How the screen works", 3)
para(doc, "The screen shows source statements grouped under their Source Structure hierarchy, with "
          "the practices already mapped to each. Mapping is done by selection rather than by opening "
          "a form for every pair:")
step(doc, "Use the Authority, Artifact and Release filters to narrow to the release you are mapping.")
step(doc, "Find the statement in the tree - structure nodes act as folders, so expand down to the "
          "statements.")
step(doc, "Select the statement, then tick every practice that answers it in the practice list. The "
          "list carries its own search box.")
step(doc, "Confirm the prompt - it tells you how many statements you are about to map to the practice.")
step(doc, "To remove mappings, select them and use the remove control; a confirmation names how many "
          "mappings will be removed.")

heading(doc, "Fields", 3)
table(doc, FIELD_HEADERS, [
    ("Framework Statement", "Yes", "The source statement being answered."),
    ("Practices", "Yes", "One or more practices. Multi-select - map several practices to the same "
                         "statement in one action."),
    ("Status", "Yes", "Active or Retired."),
], FIELD_WIDTHS)

heading(doc, "Rules and things to watch", 3)
bullet(doc, "The pair (statement, practice) must be unique. Mapping the same practice to the same "
            "statement twice is rejected.")
bullet(doc, "A statement with no mapped practice is an open gap. Filtering for unmapped statements "
            "is the fastest gap analysis the module offers.")
bullet(doc, "There is no Add button on this screen's page heading - mapping is done from the tree, "
            "not from a blank form.")
bullet(doc, "Removing a mapping does not delete either side. The statement and the practice both "
            "survive; only the link goes.")

heading(doc, "What gets recorded", 3)
para(doc, AUDIT_STD)
screenshot(doc, "Practices - Statement Mapping: statement tree on the left, practice picker on the "
                "right, mapped count in the header.")

heading(doc, "6.4 Practices - Obligation Mapping", 2)
heading(doc, "What this screen is for", 3)
para(doc, "Where 6.3 links a practice to the regulator's words, this screen links a practice to what "
          "it must deliver, release by release. The grid groups mapped obligations by obligation; "
          "expand a row to see the practice and release combinations it is mapped to.")
para(doc, "Menu path: Repository Management > Practices - Obligation Mapping",
     italic=True, color=MUTED, size=10)

heading(doc, "The mapping matrix", 3)
para(doc, "Add and Edit open a full page. At the top you pick one Practice; the matrix below then "
          "lists every statement release that practice is mapped to, one row per statement:")
table(doc, ["Column", "What it shows"], [
    ("Authority", "The issuing body of the statement's artifact."),
    ("Artifact / Framework", "The artifact the statement belongs to."),
    ("Release / Version", "The release the statement belongs to."),
    ("Statement Reference", "The clause reference."),
    ("Statement Title", "The statement heading."),
    ("Mapped Obligations", "The multi-select where you attach obligations to this row. Several "
                           "obligations may be attached to the same cell."),
], [2200, 7160])

heading(doc, "Map obligations to a practice", 3)
step(doc, "Open Practices - Obligation Mapping and click Add.")
step(doc, "Choose the Practice. Until you do, the matrix shows 'Pick a Practice to load mapped "
          "statement releases.'")
step(doc, "The matrix loads with one row per statement the practice is mapped to. If it comes back "
          "empty, the practice has no statement mappings yet - go to 6.3 first.")
step(doc, "On each row, open Mapped Obligations and tick the obligations that apply on that statement "
          "and release.")
step(doc, "Click Save Mappings in the bottom bar.")

callout(doc, "Why an obligation might not be in the list",
        "Each row offers the obligations that were mapped to a source statement of that release on "
        "the Obligation Master screen, plus every obligation with no statement mapping at all. If an "
        "obligation you expect is missing, open it in Obligation Master and check its Source "
        "Statement Mapping section - it is probably mapped to a different release.")

heading(doc, "Grid columns", 3)
para(doc, "The grid itself shows Obligation Name, Execution Frequency, Assurance Frequency, Retention "
          "Period, Evidence count, Mappings count and Status, so you can see at a glance which "
          "obligations are richly mapped and which are orphans.")

heading(doc, "Rules and things to watch", 3)
bullet(doc, "The combination of practice, release, statement and obligation must be unique among "
            "active rows.")
bullet(doc, "Mapping is driven from the practice. To map one obligation to many practices, repeat the "
            "flow once per practice.")
bullet(doc, "An obligation with a Mappings count of zero is doing nothing. Either map it or retire it.")

heading(doc, "What gets recorded", 3)
para(doc, AUDIT_STD)

doc.add_page_break()


# ---------------------------------------------------------------------------
# 7. Event-driven assurance
# ---------------------------------------------------------------------------

heading(doc, "7. Event-driven assurance", 1)
para(doc, "Some verification cannot be scheduled - it has to happen because something happened. A new "
          "vendor is onboarded, an employee leaves, a system goes live. This chapter covers recording "
          "that something happened, and working through the checklist it generates.")

callout(doc, "Where the checklist comes from",
        "Nothing is configured on these screens. The items on a checklist are the Event-driven "
        "Assurance obligations authored in Obligation Master (6.2) that name the event you raised. "
        "Configure there; operate here.")

heading(doc, "7.1 Raise Event", 2)
heading(doc, "What this screen is for", 3)
para(doc, "Recording that a tracked event occurred. Doing so generates a checklist containing every "
          "assurance configured for that event, each with its own due date.")
para(doc, "Menu path: Repository Management > Event Checklists, then Raise Event",
     italic=True, color=MUTED, size=10)

heading(doc, "Fields on the form", 3)
table(doc, FIELD_HEADERS, [
    ("Event Domain", "Yes", "The family the event belongs to - the first step of the picker. Choose it "
                            "and the Event dropdown becomes available."),
    ("Event", "Yes", "The specific event within that domain. Disabled until a domain is chosen; the "
                     "placeholder reads '-- Select a domain first --'."),
    ("Occurred On", "No", "The date the event actually happened. Defaults to today. Set it back if "
                          "you are recording something after the fact - due dates are calculated "
                          "from this date."),
    ("Subject", "Yes", "Who or what the event happened to. The list depends on the event you chose, "
                       "so it stays disabled until then ('-- Select an event first --')."),
    ("Remarks", "No", "Context for whoever works the checklist."),
], FIELD_WIDTHS)

heading(doc, "Raise an event", 3)
step(doc, "Open Event Checklists and click Raise Event.")
step(doc, "Choose the Event Domain.")
step(doc, "Choose the Event.")
step(doc, "Check Occurred On. It defaults to today - correct it if the event was earlier.")
step(doc, "Choose the Subject.")
step(doc, "Read the Checklist Preview panel that appears once an event is chosen. It lists the "
          "assurances that will be raised, so you can see whether anything is configured before "
          "committing.")
step(doc, "Add Remarks if useful, then click Raise Event.")

callout(doc, "An empty preview is a warning",
        "If the preview shows nothing, raising the event will produce an empty checklist. That means "
        "no Event-driven Assurance obligation names this event. Fix the configuration in Obligation "
        "Master before raising it, rather than raising an empty one.", WARN_FILL)

heading(doc, "Rules and things to watch", 3)
bullet(doc, "Raise Event requires Add rights on Event Checklists. Without them the button is not shown.")
bullet(doc, "Occurred On drives every due date on the generated checklist. Getting it wrong makes "
            "items overdue that are not, or hides ones that are.")
bullet(doc, "The verification method captured on each checklist item is a snapshot taken at the moment "
            "the event was raised. Editing the obligation afterwards does not rewrite checklists "
            "already raised - which is the point.")

heading(doc, "7.2 Event Checklists", 2)
heading(doc, "What this screen is for", 3)
para(doc, "One row per event that occurred, with completion progress across the checklist it "
          "generated. It is the operational worklist for event-driven assurance.")
para(doc, "Menu path: Repository Management > Event Checklists", italic=True, color=MUTED, size=10)

heading(doc, "Grid columns", 3)
table(doc, ["Column", "What it shows"], [
    ("Event Name", "The event that occurred."),
    ("Subject", "Who or what it happened to."),
    ("Occurred On", "The date recorded when the event was raised."),
    ("Next Due On", "The earliest outstanding due date across the checklist - your triage column."),
    ("Completed / Pending / Overdue", "Item counts. Overdue is calculated on the server against "
                                      "database time, so a wrong clock on your machine cannot make "
                                      "work look late."),
    ("Status", "Where the occurrence stands overall."),
], [2400, 6960])

heading(doc, "7.3 Completing a checklist", 2)
para(doc, "Click a row to open its checklist page. A summary header shows the event, the subject and "
          "the progress; below it is one card per assurance item, each showing the verification "
          "method snapshot, the due date, and whether it is Pending, Completed or Overdue.")

heading(doc, "Record a result", 3)
step(doc, "Find the item card.")
step(doc, "Choose a result: Pass, Fail or Not Applicable.")
step(doc, "Type Remarks. They are optional for Pass and Not Applicable, and mandatory for Fail - the "
          "placeholder changes to 'Remarks (required for Fail)' as soon as you choose Fail, and the "
          "save is refused without them.")
step(doc, "Save the item. It flips to Completed and records who completed it and when.")
step(doc, "Work through the remaining items. Use Back to Event Checklists when you are done.")

heading(doc, "Rules and things to watch", 3)
bullet(doc, "A Fail must be explained. This is enforced both in the page and in the database, so "
            "there is no way round it - and a Fail without a reason is useless to the next reviewer.")
bullet(doc, "Overdue items carry a red marker showing how late they are. The marker disappears once "
            "the item is completed - a completed item is not retroactively 'late'.")
bullet(doc, "Items due within three days are highlighted so they stand out before they slip.")
bullet(doc, "Completed items become read-only, showing the result, the remarks, and the name and date "
            "of whoever completed them.")
bullet(doc, "Checklist completion does not go through maker-checker. It is operational evidence, not "
            "policy, and is written directly - but it is fully audited.")

heading(doc, "What gets recorded", 3)
para(doc, "Each completion records the result, the remarks, the completing user and the completion "
          "timestamp against the item, and updates the counts on the occurrence row.")
screenshot(doc, "Event Checklist page: summary header with progress, item cards showing Pass/Fail/Not "
                "Applicable, one overdue item flagged.")

doc.add_page_break()
# ---------------------------------------------------------------------------
# 8. Assurance Management
# ---------------------------------------------------------------------------

heading(doc, "8. Assurance Management", 1)
para(doc, "These screens hold the reusable vocabulary that assurance work draws on - categories, "
          "scoring methods, severities, workflows, SLAs. They are set up once by an administrator and "
          "then referenced everywhere, so a change here changes the meaning of every assessment that "
          "uses it. That is why they carry a lifecycle rather than a simple Active/Retired flag.")
para(doc, "Breadcrumb: the metadata masters show 'Assurance Management / ...' at the top of the "
          "page rather than 'Repository Management / ...'. SLA Master (8.12) is the exception - "
          "it carries the Repository Management breadcrumb.", italic=True, color=MUTED, size=10)

heading(doc, "8.1 The assurance lifecycle", 2)
para(doc, "Every assurance master moves through a lifecycle, shown in its own Lifecycle column beside "
          "the ordinary Status. The actions available on the 3-dot menu depend on where the record "
          "currently sits and on your permissions.")
table(doc, ["Lifecycle", "Available action", "Who can do it", "Result"], [
    ("Draft", "Submit for Review", "Edit rights", "Moves the record to Review. You are prompted for "
                                                  "optional remarks."),
    ("Review", "Approve", "Approve rights", "Moves the record to Approved."),
    ("Review", "Reject", "Approve rights", "Sends the record back."),
    ("Approved", "Publish", "Approve rights", "Makes the version live and usable."),
    ("Published", "Publish New Version", "Approve rights", "Starts a new version, leaving the "
                                                           "published one intact."),
    ("Published", "Retire", "Approve rights", "Archives the published version."),
], [1400, 2300, 1800, 3860])
callout(doc, "Remarks are captured on every transition",
        "Each lifecycle action prompts for remarks. They are optional, but they are written to the "
        "immutable Version History (8.13) - which is the only place a later reader will find out why "
        "a scoring model was retired.")

ASSURANCE_COMMON_RULES = [
    "Code must be unique within the master. It is what other screens reference.",
    "Version and Lifecycle are managed by the system - the form does not offer them.",
    "The record is only usable elsewhere once it is Published.",
]


def assurance_master(number, title, purpose, fields, extra_rules=None, shot=None):
    screen_section(
        doc, number, title, f"Assurance Management > {title}",
        purpose=purpose, when=None, fields=fields,
        rules=ASSURANCE_COMMON_RULES + (extra_rules or []),
        audit="Every add, edit and lifecycle transition writes an immutable row to Version History "
              "(8.13) carrying the entity, the version, the lifecycle status, the action, who did it "
              "and when.",
        shot=shot,
    )


assurance_master(
    "8.2", "Assurance Categories",
    "A reusable set of categories that classify assurance work - the buckets assessments are sorted "
    "into for reporting and filtering.",
    [
        ("Category Code", "Yes", "Short unique code."),
        ("Category Name", "Yes", "Display name."),
        ("Description", "No", "What belongs in this category."),
        ("Display Order", "No", "Controls where the category appears in lists. Whole numbers, 0 or "
                                "more."),
        ("Status", "Yes", "Active or Retired."),
    ])

assurance_master(
    "8.3", "Scoring Models",
    "A reusable scoring methodology - how an assessment turns answers into a result, and what counts "
    "as a pass.",
    [
        ("Model Code", "Yes", "Short unique code."),
        ("Model Name", "Yes", "Display name."),
        ("Description", "No", "When to use this model."),
        ("Formula Type", "No", "The kind of calculation: Percentage, PassFail, WeightedAvg, "
                               "RiskMatrix, Maturity or Compliance."),
        ("Formula Definition", "No", "Configuration for the formula. Configuration values only - "
                                     "free-text SQL is rejected by the server."),
        ("Rating Scale", "No", "The scale results are expressed on, e.g. '0-100' or "
                               "'Low;Medium;High;Critical'."),
        ("Pass Threshold", "No", "The score at or above which the assessment passes. Decimals allowed."),
        ("Status", "Yes", "Active or Retired."),
    ],
    ["Formula Definition accepts configuration only. Anything that looks like executable SQL is "
     "refused - this is a deliberate safety control, not a bug."])

assurance_master(
    "8.4", "Observation Severity",
    "The default severity classifications applied to observations raised during assurance work.",
    [
        ("Severity Code", "Yes", "Short unique code."),
        ("Severity Name", "Yes", "Display name, e.g. Critical, High, Medium, Low."),
        ("Description", "No", "What qualifies for this severity."),
        ("Severity Rank", "No", "A whole number of 1 or more that orders severities. Lower numbers "
                                "are more severe by convention - keep the convention consistent."),
        ("Color Code", "No", "A hex colour used in reports and dashboards, e.g. #c92a2a."),
        ("Status", "Yes", "Active or Retired."),
    ])

assurance_master(
    "8.5", "Gap Categories",
    "The standard classification for gaps found during assurance - what kind of shortfall this is.",
    [
        ("Gap Code", "Yes", "Short unique code."),
        ("Gap Name", "Yes", "Display name."),
        ("Description", "No", "What kind of gap belongs here."),
        ("Display Order", "No", "Ordering in lists."),
        ("Status", "Yes", "Active or Retired."),
    ])

assurance_master(
    "8.6", "Workflow Templates",
    "A reusable workflow model - the stages a piece of assurance work passes through, with its SLA and "
    "escalation behaviour.",
    [
        ("Template Code", "Yes", "Short unique code."),
        ("Template Name", "Yes", "Display name."),
        ("Description", "No", "What this workflow is for."),
        ("SLA (hours)", "No", "The overall time allowance for the workflow, in hours."),
        ("Escalation Rule", "No", "What happens, and to whom, when the SLA is breached."),
        ("Status", "Yes", "Active or Retired."),
    ])

assurance_master(
    "8.7", "Question Types",
    "The kinds of question an assurance questionnaire may ask, and the shape of answer each expects.",
    [
        ("Question Code", "Yes", "Short unique code."),
        ("Question Name", "Yes", "Display name."),
        ("Description", "No", "When to use this question type."),
        ("Answer Shape", "No", "What the answer looks like: Boolean, Choice, Text, Number, Date, "
                               "Rating, Observation, Evidence or Checklist."),
        ("Requires Evidence", "No", "Yes or No - whether an answer must be backed by an attachment."),
        ("Display Order", "No", "Ordering in lists."),
        ("Status", "Yes", "Active or Retired."),
    ])

assurance_master(
    "8.8", "Sampling Models",
    "Reusable sampling methodologies - how a population is sampled when a control cannot be tested in "
    "full.",
    [
        ("Sampling Code", "Yes", "Short unique code."),
        ("Sampling Name", "Yes", "Display name."),
        ("Description", "No", "When this sampling approach applies."),
        ("Methodology", "No", "How the sample is drawn and sized, in enough detail to be repeatable."),
        ("Status", "Yes", "Active or Retired."),
    ])

assurance_master(
    "8.9", "Frequency Types",
    "The reusable execution frequencies referenced by obligations and assurance schedules.",
    [
        ("Frequency Code", "Yes", "Short unique code."),
        ("Frequency Name", "Yes", "Display name, e.g. Monthly, Quarterly, Annual."),
        ("Description", "No", "What the cadence means in practice."),
        ("Interval (days)", "No", "The frequency expressed in days, used by scheduling. 0 or more."),
        ("Display Order", "No", "Ordering in lists."),
        ("Status", "Yes", "Active or Retired."),
    ],
    ["These are the values that appear in the Execution Frequency and Assurance Frequency dropdowns on "
     "the Obligation Master form. Adding one here makes it available there - no code change is needed."])

assurance_master(
    "8.10", "Report Templates",
    "Reusable report layouts for assurance output.",
    [
        ("Template Code", "Yes", "Short unique code."),
        ("Template Name", "Yes", "Display name."),
        ("Description", "No", "What the report shows and who reads it."),
        ("Report Scope", "No", "Executive, Engagement, Register or Dashboard."),
        ("Layout Definition", "No", "The layout configuration for the template."),
        ("Status", "Yes", "Active or Retired."),
    ])

assurance_master(
    "8.11", "Starter Assurance Templates",
    "Ready-to-subscribe bundles that tie the other masters together, so a new assurance programme can "
    "be started from a known-good combination rather than assembled field by field.",
    [
        ("Template Code", "Yes", "Short unique code."),
        ("Template Name", "Yes", "Display name."),
        ("Description", "No", "What this starter template sets up."),
        ("Assurance Category", "No", "From 8.2."),
        ("Scoring Model", "No", "From 8.3."),
        ("Workflow Template", "No", "From 8.6."),
        ("Sampling Model", "No", "From 8.8."),
        ("Frequency Type", "No", "From 8.9."),
        ("Report Template", "No", "From 8.10."),
        ("Status", "Yes", "Active or Retired."),
    ],
    ["Every dropdown here is fed by another assurance master. If one is empty, create and publish the "
     "underlying master first."])

heading(doc, "8.12 SLA Master", 2)
heading(doc, "What this screen is for", 3)
para(doc, "An SLA defines how long a process has before it is breached, and at what point warnings and "
          "escalations fire. SLAs are defined per process and severity classification, and drive the "
          "breach alerts across the assurance runtime.")
para(doc, "Menu path: Repository Management > SLA Master", italic=True, color=MUTED, size=10)

heading(doc, "Fields on the form", 3)
table(doc, FIELD_HEADERS, [
    ("SLA ID", "Auto", "Generated on save as SLA-039 and so on. Read-only."),
    ("Process", "Yes", "The process this SLA governs - Gap Analysis, Gap Remediation, Risk Assessment, "
                       "Risk Treatment, Exception Approval / Action / Review, Task Execution, "
                       "Continuous Assurance, Event Assurance, Obligation Fulfilment, Custom Task or "
                       "Periodic Review."),
    ("Classification", "Yes", "Critical, High or Standard. Process plus classification must be unique."),
    ("Duration Value", "Yes", "A whole number from 1 to 3650."),
    ("Duration Unit", "Yes", "Hours or Days."),
    ("Time Basis", "Yes", "Business Hours, Business Days, Business Day or Calendar Days. The business "
                          "bases honour the working calendar; Calendar Days counts every day including "
                          "weekends and holidays."),
    ("Warning %", "Yes", "Percent of the SLA elapsed before a warning is raised. 1 to 99. Default 75."),
    ("Escalation %", "Yes", "Percent elapsed before escalation. 2 to 100. Default 90. Must be strictly "
                            "greater than Warning %."),
    ("Status", "Yes", "Active or Inactive."),
    ("Effective From", "No", "The date this SLA starts applying."),
    ("Remarks", "No", "Up to 500 characters. Becomes mandatory in deactivate mode - see below."),
], FIELD_WIDTHS)

heading(doc, "Add or edit an SLA", 3)
step(doc, "Open SLA Master and click Add, or choose Edit on a row. A full page opens.")
step(doc, "Pick the Process and the Classification.")
step(doc, "Set Duration Value, Duration Unit and Time Basis.")
step(doc, "Adjust Warning % and Escalation % if the defaults of 75 and 90 do not suit.")
step(doc, "Set Effective From and Remarks if relevant.")
step(doc, "Click Save SLA.")

heading(doc, "Deactivate an SLA", 3)
para(doc, "Deactivation opens the same page in a distinct mode: every field is locked except Status "
          "and the Remarks box, which is relabelled Deactivation Reason and becomes mandatory. The "
          "button in the action bar reads Confirm Deactivate and is styled red.")
step(doc, "Choose Inactive on the row.")
step(doc, "Type the Deactivation Reason - it is captured as evidence of why the SLA was withdrawn.")
step(doc, "Click Confirm Deactivate.")

heading(doc, "Rules and things to watch", 3)
bullet(doc, "Warning % must be strictly less than Escalation %. Equal values are rejected.")
bullet(doc, "Process plus Classification must be unique - one SLA per pair.")
bullet(doc, "Choose the Time Basis deliberately. 'Days' on a Calendar Days basis and 'Days' on a "
            "Business Days basis are materially different deadlines.")
bullet(doc, "Deactivation without a reason is refused. The mandatory remark is the point of the "
            "separate mode.")

heading(doc, "What gets recorded", 3)
para(doc, AUDIT_STD)

heading(doc, "8.13 Version History", 2)
heading(doc, "What this screen is for", 3)
para(doc, "The immutable lifecycle trail for every assurance metadata item: what it was, which "
          "version, what lifecycle status it moved to, which action caused it, who did it and when.")
para(doc, "Menu path: Assurance Management > Version History", italic=True, color=MUTED, size=10)
heading(doc, "Columns", 3)
table(doc, ["Column", "What it shows"], [
    ("Entity Type", "Which assurance master the row belongs to."),
    ("Entity ID", "The record's identifier."),
    ("Version", "The version number at the time of the action."),
    ("Lifecycle Status", "The status the record moved to."),
    ("Action", "The transition - submit, approve, reject, publish, retire."),
    ("Changed By / Changed On", "Who performed it and when."),
    ("Remarks", "The comments captured on the transition."),
], [2000, 7360])
para(doc, "This screen is read-only. It has no Add button, no Edit or Inactive on the 3-dot menu, and "
          "no status filter - it is a log, and logs are not edited.")

doc.add_page_break()
# ---------------------------------------------------------------------------
# 9. Bulk Excel Upload
# ---------------------------------------------------------------------------

heading(doc, "9. Bulk Excel Upload", 1)
heading(doc, "What this screen is for", 3)
para(doc, "Loading an entire artifact chain in one go - authority, artifact, release, structure, "
          "statements, practices, obligations and mappings - from a single Excel workbook. Nothing is "
          "inserted until every row passes validation, and the commit is all-or-nothing.")
para(doc, "Menu path: Repository Management > Bulk Upload", italic=True, color=MUTED, size=10)

heading(doc, "9.1 The three steps", 2)
step(doc, "Download the template.")
step(doc, "Fill it in, upload it, and click Validate. Validation does not touch the database.")
step(doc, "Read the result. If validation passed, click Commit Upload.")

heading(doc, "9.2 The workbook", 2)
para(doc, "The template carries one sheet per business table, in dependency order - parents before "
          "children, because the commit resolves references by looking up rows inserted earlier in "
          "the same run. Each sheet has its headers and inline instructions.")
table(doc, ["Sheet", "What it loads", "Key columns"], [
    ("Authority", "Issuing bodies.",
     "authorityCode*, authorityName*, description, jurisdiction, website"),
    ("Artifact", "Regulations and standards.",
     "authorityCode*, artifactCode*, artifactName*, description, artifactCategory*, industry, "
     "jurisdiction"),
    ("Release", "Versioned publications.",
     "artifactCode*, versionNo*, effectiveDate, endDate, releaseNotes"),
    ("SourceStructure", "The native hierarchy.",
     "artifactCode*, versionNo*, parentNodeReference, nodeLevel*, nodeType*, nodeReference*, "
     "nodeTitle, description, displayOrder"),
    ("SourceStatement", "The regulatory text.",
     "artifactCode*, versionNo*, structureNodeReference*, classificationCode, statementReference*, "
     "statementTitle, statementText*, statementType, remarks, displayOrder"),
    ("Practice", "The global practices master.",
     "requirementCode*, requirementName*, requirementStatement*, objective, keywords"),
    ("Obligation", "The global obligation master.",
     "obligationName*, obligationText, executionFrequencyCode, retentionRequirement, remarks"),
    ("ObligationEvidence", "Evidence types under an obligation.",
     "obligationName*, evidenceTypeCode*, assuranceFrequencyCode, retentionRequirement, remarks"),
    ("PracticeSourceStatementMapping", "Practice to statement links.",
     "artifactCode*, versionNo*, statementReference*, requirementCode*"),
    ("PracticeObligationMapping", "Obligation to practice/release links.",
     "obligationName*, targetRequirementCode*, targetArtifactCode*, targetVersionNo*, "
     "targetStatementReference"),
], [2300, 2300, 4760])
para(doc, "* marks a mandatory column.", italic=True, color=MUTED, size=10)

heading(doc, "9.3 Filling the workbook", 2)
bullet(doc, "Codes are the glue. A row references its parent by code, not by number - artifactCode "
            "plus versionNo identifies a release, nodeReference identifies a structure node.")
bullet(doc, "A referenced code may be in the same workbook or already in the database. Both work; "
            "sheet order guarantees the workbook's own rows are inserted first.")
bullet(doc, "Dates go in as YYYY-MM-DD. Leave endDate blank for an open-ended release.")
bullet(doc, "nodeLevel is 1 for top-level nodes and increases by 1 per depth. parentNodeReference is "
            "blank for root nodes.")
bullet(doc, "Keywords are comma-separated inside a single cell.")
bullet(doc, "obligationName is the key the evidence and mapping sheets resolve against. If two active "
            "obligations share a name - in the file or in the database - every row referencing that "
            "name is rejected as ambiguous.")
bullet(doc, "Respect the length limits in the instructions. Long text columns cap at 4000 characters, "
            "names and titles lower.")

heading(doc, "9.4 Validate", 2)
step(doc, "Click Choose File and pick your completed .xlsx. Only .xlsx is accepted.")
step(doc, "Click Validate.")
step(doc, "Read Step 3 - Result. It shows a green banner if validation passed and a red one if not.")
step(doc, "Check the Sheet Summary table: sheet, table, total rows, valid rows, invalid rows.")
step(doc, "If there are problems, the Issues table lists them by sheet, row, column and message - the "
          "first 500 on screen.")
step(doc, "Click Download Error Report for the full list as an Excel file. Fix the rows in your "
          "workbook and validate again.")
callout(doc, "Validation never writes anything",
        "You can validate as many times as you like. The database is untouched until you press Commit "
        "Upload, which stays disabled until a validation passes.")

heading(doc, "9.5 Commit", 2)
step(doc, "With a passing validation on screen, click Commit Upload.")
step(doc, "Confirm the prompt: 'This will insert every valid row from the workbook. Continue?'")
step(doc, "Wait for the result. On success the banner names how many rows went into each table.")
para(doc, "The commit runs as a single all-or-nothing transaction. If anything fails part way, nothing "
          "is written and the workbook can be corrected and re-committed - you will not be left with a "
          "half-loaded artifact.")

heading(doc, "9.6 Common validation messages", 2)
table(doc, ["Message pattern", "What it means", "Fix"], [
    ("... must match an Authority row in this file or an active authority in the database",
     "The authorityCode on an Artifact row does not resolve.",
     "Check the spelling, or add the authority to the Authority sheet."),
    ("Unique ... code", "A code is duplicated, in the file or against existing data.",
     "Codes are unique across the whole table, not just within the sheet."),
    ("Rejected if ambiguous", "Two active obligations share the obligationName being referenced.",
     "Rename one of them, or reference the intended one after retiring the other."),
    ("Must match a nodeReference in the same release",
     "A statement points at a structure node that does not exist in that release.",
     "Add the node to SourceStructure, or correct structureNodeReference."),
    ("Required", "A mandatory column is blank.", "Fill it. The sheet instructions mark which are "
                                                 "mandatory."),
], [3000, 3100, 3260])

doc.add_page_break()


# ---------------------------------------------------------------------------
# 10. Single-Form Upload
# ---------------------------------------------------------------------------

heading(doc, "10. Single-Form Excel Upload", 1)
heading(doc, "What this screen is for", 3)
para(doc, "Loading one form at a time into one release. Use it to top up a release that already "
          "exists, where the full bulk workbook would be overkill. The template is signed, so the "
          "release it was generated for cannot be silently swapped after download.")
para(doc, "Menu path: Repository Management > Single-Form Upload", italic=True, color=MUTED, size=10)

heading(doc, "10.1 The forms available", 2)
table(doc, ["Form", "Release-scoped?", "What it loads"], [
    ("Source Structure", "Yes", "Structure nodes into the selected release. parentNodeReference must "
                                "be blank (root) or match another row in the file or an existing "
                                "active node in the same release."),
    ("Source Statement", "Yes", "Statements into the selected release. structureNodeReference must "
                                "already exist in that release."),
    ("Practices", "No", "The global practices master. requirementCode is unique across all releases."),
    ("Obligation Master", "No", "The global obligation master. executionFrequencyCode resolves "
                                "against the frequency reference list."),
    ("Obligation Evidence Types", "No", "Evidence types under existing obligations, keyed by "
                                        "obligation name, evidence type and assurance frequency."),
    ("Practice - Source Statement Mapping", "Yes", "Links an existing practice to a statement in the "
                                                   "selected release."),
    ("Practice Obligation Mapping", "Yes", "Maps an obligation onto a target release, practice and "
                                           "optional statement. The Release dropdown selects the "
                                           "TARGET release."),
], [2600, 1400, 5360])

heading(doc, "10.2 Step 1 - select form and release", 2)
step(doc, "Choose the Form. A help line underneath explains what that form loads.")
step(doc, "If the form is release-scoped, a Release dropdown appears. Choose the release. Only Draft "
          "and Active releases are listed - a retired release cannot be topped up.")
step(doc, "Click Download Template. The button stays disabled until the selection is complete.")
callout(doc, "The template is signed",
        "A release-scoped template carries two read-only helper columns - Release and ReleaseId - and "
        "a hidden context sheet holding the entity, the release and a signature. Editing the "
        "ReleaseId, the entity or the timestamp invalidates the signature and the upload is rejected. "
        "Do not copy rows between templates generated for different releases; download a fresh "
        "template instead.", WARN_FILL)

heading(doc, "10.3 Step 2 - choose the upload mode", 2)
table(doc, ["Mode", "What it does", "When to use it"], [
    ("Add new only (Insert)", "Keeps every existing row and adds the new ones. This is the default.",
     "Almost always. Recommended."),
    ("Replace - retire existing + add new",
     "Deletes all existing rows in this scope, then inserts the ones in your file. Offered only on "
     "forms that support it, and blocked automatically when other records reference the rows you "
     "would remove.",
     "Reloading a release's structure or statements wholesale after a correction. Destructive - treat "
     "it as a last resort."),
], [2400, 4000, 2960])

heading(doc, "Using Replace safely", 3)
step(doc, "Choose Replace. A preview panel appears summarising what would be removed and listing any "
          "blockers.")
step(doc, "Read the blockers. If external references exist, the operation is refused - remove those "
          "references first or use Insert mode.")
step(doc, "If it is allowed, type the release code exactly as shown into the confirmation box. This is "
          "deliberate friction.")
step(doc, "Continue to validate and commit as normal.")
para(doc, "The server re-checks every blocker under a transaction lock at commit time, so a reference "
          "created by somebody else while you were reading the preview will still stop the delete. The "
          "whole operation is atomic.")

heading(doc, "10.4 Steps 3 and 4 - validate, commit, read the result", 2)
step(doc, "Fill in the downloaded template and save it.")
step(doc, "Click Choose File and select it, then click Validate.")
step(doc, "Read the Summary and Issues tables - same format as the bulk upload.")
step(doc, "Fix any issues in the workbook and validate again.")
step(doc, "When validation passes, Commit Upload becomes available. Click it.")
step(doc, "Read the result banner. It reports how many rows were inserted.")

heading(doc, "10.5 Rules and things to watch", 2)
bullet(doc, "Only .xlsx files are accepted.")
bullet(doc, "Do not rename sheets, reorder columns or delete the helper columns. The validator matches "
            "on them.")
bullet(doc, "Do not delete or edit the hidden context sheet on a release-scoped template.")
bullet(doc, "Your permissions still apply. Each form is gated on the same permission area as its "
            "screen, so you cannot upload into something you could not add by hand.")
bullet(doc, "Replace is not offered on the Practices and Obligation Master forms - they are global "
            "masters with too many downstream references.")

doc.add_page_break()


# ---------------------------------------------------------------------------
# 11. Change Management
# ---------------------------------------------------------------------------

heading(doc, "11. Change Management (maker-checker)", 1)
para(doc, "On modules covered by an approval workflow, a maker's save does not change the live record. "
          "It creates a change request that a different person reviews. This chapter covers both "
          "sides of that exchange.")

heading(doc, "11.1 Change Management screen", 2)
heading(doc, "What this screen is for", 3)
para(doc, "Every pending and historical change request, with who raised it, who checked it and what "
          "was decided.")
para(doc, "Menu path: Repository Management > Change Management", italic=True, color=MUTED, size=10)

heading(doc, "Columns", 3)
table(doc, ["Column", "What it shows"], [
    ("Change Request Number", "The system-generated reference for the request."),
    ("Module", "Which screen the change came from."),
    ("Record Reference", "The record being changed."),
    ("Action Type", "Add, Edit, Inactive, Activate, Approve, Reject or Send Back."),
    ("Maker / Submitted On", "Who raised it and when."),
    ("Checker / Checked On", "Who decided it and when - blank while pending."),
    ("Status", "Pending Approval, Approved, Auto Approved, Rejected or Sent Back."),
], [2200, 7160])

heading(doc, "11.2 Reviewing a change as a checker", 2)
step(doc, "Open Change Management and filter Status to Pending Approval. The module and action-type "
          "filters narrow it further.")
step(doc, "Open the 3-dot menu on the request and choose View Change.")
step(doc, "Read the detail. The view shows the field-level changes, the old data and the proposed "
          "data, so you can see exactly what would be written.")
step(doc, "Decide, using the 3-dot menu on the row.")

heading(doc, "The three decisions", 3)
table(doc, ["Decision", "Comments", "What happens"], [
    ("Approve", "Optional", "The proposed data is applied to the live record. The request moves to "
                            "Approved and the audit trail records both the change and the approval."),
    ("Reject", "Mandatory", "The request is closed without applying anything. The live record is "
                            "untouched. The maker must start again."),
    ("Send Back", "Mandatory", "The request goes back to the maker for correction, carrying your "
                               "comments."),
], [1600, 1600, 6160])
callout(doc, "Reject and Send Back require a reason",
        "Approval comments are optional; reject and send-back comments are not. Leaving them blank "
        "produces 'Checker comments are mandatory.' and the action is refused. The comment is what "
        "tells the maker what to fix.", WARN_FILL)

heading(doc, "Linked changes", 3)
para(doc, "Some saves produce several related requests - an obligation saved with its typed detail, "
          "evidence rows and statement mappings, for instance. Those arrive as one bundle and the "
          "confirmation says so ('Approve Linked Changes'). Deciding on the bundle decides on all of "
          "it; you cannot approve half.")

heading(doc, "11.3 What a maker sees", 2)
bullet(doc, "On save: 'Change submitted for approval. The main record will update after checker "
            "approval.'")
bullet(doc, "The grid still shows the old values - because they are still the truth until a checker "
            "acts.")
bullet(doc, "Track the request on Change Management, filtered to your own submissions.")
bullet(doc, "A sent-back request comes back with the checker's comments. Correct the record and save "
            "again; a new request is raised.")

heading(doc, "11.4 Approval Workflow Configuration", 2)
heading(doc, "What this screen is for", 3)
para(doc, "Deciding which modules need maker-checker at all, and who may play which part. This is an "
          "administrator screen - changing it changes how everybody else's saves behave.")
para(doc, "Menu path: Repository Management > Approval Workflow Configuration",
     italic=True, color=MUTED, size=10)

heading(doc, "Fields on the form", 3)
table(doc, FIELD_HEADERS, [
    ("Module", "Yes", "Which module this rule governs."),
    ("Maker Roles", "No", "The roles whose members may raise changes on this module."),
    ("Maker Users", "No", "Named users who may raise changes, in addition to the roles."),
    ("Checker Roles", "No", "The roles whose members may decide them."),
    ("Checker Users", "No", "Named checkers, in addition to the roles."),
    ("Approval Required", "Yes", "Yes or No. Set to No and saves on this module apply immediately with "
                                 "the 'auto-approved' message."),
    ("Self Approval Allowed", "Yes", "Yes or No. Whether the person who raised a change may also "
                                     "approve it. Set to No to enforce genuine four-eyes."),
    ("Minimum Approvers", "Yes", "How many approvals a request needs. 1 or more."),
    ("Status", "Yes", "Active or Inactive."),
], FIELD_WIDTHS)

heading(doc, "Rules and things to watch", 3)
bullet(doc, "Setting Approval Required to No on a module removes the safety net for every user on it. "
            "The change is itself audited.")
bullet(doc, "Self Approval Allowed = Yes and Minimum Approvers = 1 together mean a maker can approve "
            "their own work. That may be correct for a low-risk module; be sure it is deliberate.")
bullet(doc, "A user with no maker role on a module cannot raise changes on it, no matter what the "
            "role-permission matrix says.")

heading(doc, "What gets recorded", 3)
para(doc, AUDIT_STD)

doc.add_page_break()
# ---------------------------------------------------------------------------
# 12. Access administration
# ---------------------------------------------------------------------------

heading(doc, "12. Access administration", 1)
para(doc, "Four screens control who exists, what they may do, and what they can see. They are "
          "administrator screens; most users will never open them.")

screen_section(
    doc, "12.1", "User Management", "Repository Management > User Management",
    purpose="The people who may sign in, and the roles each of them carries.",
    when="Onboarding a joiner, changing somebody's role, deactivating a leaver, or resetting a "
         "forgotten password.",
    fields=[
        ("User Name", "Yes", "The person's display name, shown in the top bar and in every audit row."),
        ("Login ID", "Yes", "What they type to sign in. Must be unique."),
        ("Email", "Yes", "A valid email address. It is an alternative sign-in identifier, so it must "
                         "also be unique."),
        ("Roles", "No", "Tick every role this person carries. Multi-select with a search box. Roles "
                        "are cumulative - a user gets the union of every permission their roles "
                        "grant."),
        ("Remarks", "No", "Notes about the account - department, purpose, review date."),
        ("Status", "Yes", "Active or Inactive. Users are deactivated, not retired."),
    ],
    row_actions=[
        ("Reset Password", "Sets the account back to the default password and re-arms the first-login "
                           "flow, so the user must choose a new one on their next sign-in. A "
                           "confirmation appears first. This is the action to run after somebody uses "
                           "Forgot Password."),
    ],
    rules=[
        "Login ID and Email must both be unique.",
        "A user with no roles can sign in but will see an empty menu - assign at least one role.",
        "Deactivate leavers rather than deleting them. Their name must stay resolvable in the audit "
        "trail, and deletion would break that.",
        "Reset Password does not tell the user. Contact them separately with the default password.",
    ],
    shot="User Management grid with the Reset Password action visible on the 3-dot menu.",
)

screen_section(
    doc, "12.2", "Role Management", "Repository Management > Role Management",
    purpose="The named roles that permissions are attached to. A role is a job, not a person.",
    when="When a new kind of user appears - a reviewer who may approve but not author, an auditor who "
         "may only read.",
    fields=[
        ("Role Name", "Yes", "The role's name, e.g. Repository Maker, Compliance Checker, Auditor."),
        ("Description", "No", "What this role is expected to do, so the next administrator "
                              "understands why it exists."),
        ("Status", "Yes", "Active or Inactive."),
    ],
    rules=[
        "Creating a role grants nothing on its own. Give it permissions on the Role Permission "
        "Management screen (12.4).",
        "Deactivating a role removes its permissions from everyone who holds it, immediately.",
        "Prefer several narrow roles over one broad one - a user can hold many, and separation of "
        "maker from checker depends on it.",
    ],
)

screen_section(
    doc, "12.3", "Menu Management", "Repository Management > Menu Management",
    purpose="The left navigation tree. The menu is stored in the database rather than fixed in the "
            "application, so an administrator can rename items, reorder them and regroup them without "
            "a release.",
    when="Rarely - when reorganising navigation or exposing a newly delivered screen.",
    fields=[
        ("Parent Menu", "No", "The item this one sits under. Leave blank for a top-level item."),
        ("Menu Name", "Yes", "The label users see."),
        ("Menu Code", "Yes", "The unique internal code. Permissions are granted against it, so "
                             "changing it after permissions exist will break them."),
        ("Route / URL", "No", "Where the item goes. A screen key for a repository screen, or a path."),
        ("Display Order", "Yes", "Position among its siblings. Whole numbers from 0."),
        ("Icon", "No", "The icon name shown beside the label. Leave blank for the default."),
        ("Status", "Yes", "Active or Inactive. Inactive items disappear from the menu for everyone."),
    ],
    rules=[
        "A parent item is a container - it expands rather than navigating, and its Route is ignored.",
        "Do not change a Menu Code that already has permissions granted against it.",
        "Menu changes affect every user. Check the tree yourself after editing.",
        "Removing an item from the menu hides the screen but does not revoke the permission behind it.",
    ],
)

heading(doc, "12.4 Role Permission Management", 2)
heading(doc, "What this screen is for", 3)
para(doc, "The permission matrix: for each role and each menu item, what that role may do. This is the "
          "screen that decides which buttons appear for whom.")
para(doc, "Menu path: Repository Management > Role Permission Management",
     italic=True, color=MUTED, size=10)

heading(doc, "Fields on the form", 3)
table(doc, FIELD_HEADERS, [
    ("Role", "Yes", "The role being granted."),
    ("Menu", "Yes", "The menu item - and therefore the screen - being granted on."),
    ("View", "Yes", "Yes or No. Without View the screen does not appear in the menu at all, and "
                    "reaching it by URL is refused."),
    ("Add", "Yes", "Yes or No. Controls the Add button and the add-shortcut actions on the 3-dot menu."),
    ("Edit", "Yes", "Yes or No. Controls the Edit action, and on some screens the mapping controls."),
    ("Inactive/Delete", "Yes", "Yes or No. Controls both Inactive and Activate - whoever may "
                               "deactivate may also restore."),
    ("Approve", "Yes", "Yes or No. Controls Approve on Change Management and the assurance lifecycle "
                       "transitions."),
    ("Status", "Yes", "Active or Inactive."),
], FIELD_WIDTHS)

heading(doc, "Grant permissions to a role", 3)
step(doc, "Open Role Permission Management and click Add.")
step(doc, "Choose the Role and the Menu.")
step(doc, "Set each of View, Add, Edit, Inactive/Delete and Approve to Yes or No.")
step(doc, "Save. Repeat for every menu the role needs.")
step(doc, "Ask a user with that role to sign out and back in, then confirm they see what you expect.")

heading(doc, "Rules and things to watch", 3)
bullet(doc, "View is the gate. Setting Add to Yes with View at No achieves nothing.")
bullet(doc, "Permissions are enforced twice - the web layer hides the buttons and the API "
            "independently re-checks every request. Hiding a button is not the security control; the "
            "server-side check is.")
bullet(doc, "A user's effective permission is the union across all their roles. To take a permission "
            "away you must remove it everywhere it is granted, or remove the role from the user.")
bullet(doc, "Approve and Inactive are the two to be careful with. Approve lets a user complete a "
            "maker-checker cycle; Inactive lets them take live records out of play.")
bullet(doc, "The maker-checker configuration (11.4) is a separate gate. A user can hold Edit here and "
            "still find their save routed for approval.")

heading(doc, "What gets recorded", 3)
para(doc, AUDIT_STD)

doc.add_page_break()


# ---------------------------------------------------------------------------
# 13. Audit traceability
# ---------------------------------------------------------------------------

heading(doc, "13. Audit Traceability", 1)
heading(doc, "What this screen is for", 3)
para(doc, "Who changed what, from which value to which value, and when. Every add, edit, "
          "deactivation, reactivation and approval anywhere in the module lands here, and nothing can "
          "be edited or removed from it.")
para(doc, "Menu path: Repository Management > Audit Traceability", italic=True, color=MUTED, size=10)

heading(doc, "Columns", 3)
table(doc, ["Column", "What it shows"], [
    ("Module / Entity", "Which screen and record type the change was made on."),
    ("Record Name / Reference", "Which record."),
    ("Action Type", "Add, Edit, Inactivate, Activate, Status Change or Delete."),
    ("Changed By", "The user who made the change."),
    ("Changed On", "The date and time, in IST."),
    ("Status", "The state of the record after the change."),
], [2400, 6960])
para(doc, "Expand a row to see the field-level detail: one line per changed field, showing the field "
          "name, the old value and the new value.")

heading(doc, "Finding a change", 3)
step(doc, "Filter Module / Entity to the kind of record you are investigating.")
step(doc, "Filter Action Type if you know what happened - Edit, Inactivate and so on.")
step(doc, "Use the Search box for the record's name or reference.")
step(doc, "Expand the row you want and read the old-to-new field lines.")

heading(doc, "Rules and things to watch", 3)
bullet(doc, "The screen is read-only. It has no Add button, and its 3-dot menu offers View only.")
bullet(doc, "There is no status filter here - the audit trail is a log, not a set of records with "
            "states.")
bullet(doc, "Audit rows and approval actions are append-only in the database. Nobody, including an "
            "administrator, can rewrite history.")
bullet(doc, "A retired record's audit history survives its retirement. That is the whole reason "
            "records are retired rather than deleted.")
bullet(doc, "Timestamps are displayed in IST.")
bullet(doc, "Access to this screen is itself a permission. If it is not in your menu, your role does "
            "not carry View on it.")

doc.add_page_break()


# ---------------------------------------------------------------------------
# 14. Troubleshooting
# ---------------------------------------------------------------------------

heading(doc, "14. Troubleshooting and message index", 1)
para(doc, "Look the message up here before assuming something is broken. Most of these are the "
          "application protecting data, not failing.")

heading(doc, "14.1 Signing in", 2)
table(doc, ["What you see", "Why", "What to do"], [
    ("Invalid Login ID / Email or Password.",
     "The identifier or the password did not match an active account.",
     "Retype carefully. If it persists, use Forgot Password and ask your administrator to run Reset "
     "Password on your row."),
    ("You keep being sent to Set Your Password.",
     "The account is flagged for a password change - a new account, or one just reset.",
     "Complete the page. You cannot reach any other screen until you do."),
    ("New password must be at least 8 characters long.",
     "The new password is too short.", "Choose a longer one."),
    ("Password and confirmation do not match.",
     "The two boxes differ.", "Retype the confirmation."),
    ("You are returned to the sign-in page mid-task.",
     "The session expired, or you signed out in another tab.",
     "Sign in again. Unsaved dialog content is lost - save long entries as you go."),
], [3000, 2800, 3560])

heading(doc, "14.2 Menus, screens and buttons", 2)
table(doc, ["What you see", "Why", "What to do"], [
    ("A screen described in this manual is not in my menu.",
     "Your role does not hold View on it, or the menu item is inactive.",
     "Ask your administrator to check Role Permission Management and Menu Management."),
    ("There is no Add button on the page heading.",
     "Your role does not hold Add - or the screen has no Add by design (Audit Traceability, Change "
     "Management, Practices - Statement Mapping).",
     "Check which of the two it is before raising a request."),
    ("The 3-dot menu shows fewer actions on one row than another.",
     "Actions depend on the row's status as well as your permissions - Activate replaces Inactive on "
     "an inactive row, and Approve only appears while a request is pending.",
     "Nothing - this is intended."),
    ("Forbidden / access denied after following a link.",
     "The API re-checked your permission and refused. Hiding a button is not the control.",
     "Ask your administrator for the permission you need."),
], [3000, 3200, 3160])

heading(doc, "14.3 Forms and saving", 2)
table(doc, ["What you see", "Why", "What to do"], [
    ("A dropdown is empty.",
     "The parent record has not been created, or it has been retired.",
     "Create the parent first (authority before artifact, artifact before release), or check the "
     "status filter on its own screen."),
    ("Save is refused and a field is highlighted.",
     "A mandatory field is blank or a value is out of range.",
     "Read the message under the field. Every mandatory field carries a red asterisk."),
    ("Change submitted for approval...",
     "Maker-checker is on for this module.",
     "Not an error. Track it on Change Management and tell your checker."),
    ("A duplicate-code message on save.",
     "Codes are unique across the whole table, not per parent.",
     "Choose a different code, or find and reuse the existing record."),
    ("Frequency Value / Frequency Unit is required when Frequency is Custom.",
     "A custom frequency needs both a number and a unit.",
     "Supply both, or choose a standard frequency."),
    ("Checker comments are mandatory.",
     "Reject and Send Back require a reason.", "Type the comment and retry."),
    ("Change Obligation Type? ... Change Type & Discard Detail",
     "You changed the obligation type after filling the typed panel.",
     "Cancel to keep your entries, or accept and re-enter the detail the new type asks for."),
    ("Remarks (required for Fail) on a checklist item.",
     "A failed assurance item must be explained.",
     "Type the reason, then save."),
], [3000, 2900, 3460])

heading(doc, "14.4 Uploads", 2)
table(doc, ["What you see", "Why", "What to do"], [
    ("Please choose an .xlsx file first.", "No file selected, or not an .xlsx.",
     "Select the completed template."),
    ("Validation failed with rows in the Issues table.", "One or more rows broke a rule.",
     "Download the error report, fix the workbook, validate again. Nothing was written."),
    ("Commit Upload is greyed out.", "No validation has passed yet.",
     "Validate first. The button unlocks only on a clean validation."),
    ("A row is rejected as ambiguous.", "Two active obligations share the referenced name.",
     "Rename one, or retire the one you did not mean."),
    ("The template is rejected as tampered.",
     "The ReleaseId, entity or timestamp on a signed template was edited, or rows were copied between "
     "templates.",
     "Download a fresh template for the correct release and re-enter the rows."),
    ("Replace is blocked.", "Other records reference the rows you would delete.",
     "Remove those references, or use Add new only mode."),
], [3000, 3000, 3360])

heading(doc, "14.5 Events and checklists", 2)
table(doc, ["What you see", "Why", "What to do"], [
    ("The checklist preview is empty when raising an event.",
     "No Event-driven Assurance obligation names that event.",
     "Configure one in Obligation Master before raising the event."),
    ("An item is marked overdue but I completed it on time.",
     "Overdue is computed on the server from the Occurred On date and the Due Within interval.",
     "Check that Occurred On was recorded correctly when the event was raised."),
    ("A completed item cannot be edited.",
     "Completed items are locked, carrying the result, remarks, completer and timestamp.",
     "Intended. Raise a correction through the appropriate process rather than editing evidence."),
], [3000, 3000, 3360])

doc.add_page_break()


# ---------------------------------------------------------------------------
# 15. Glossary
# ---------------------------------------------------------------------------

heading(doc, "15. Glossary", 1)
table(doc, ["Term", "Meaning"], [
    ("Authority", "The body that issues or supervises rules - a regulator, standards body or internal "
                  "policy owner. The top of the repository chain."),
    ("Artifact", "A single published document from an authority: a regulation, standard, law, "
                 "directive, circular or programme."),
    ("Release", "A dated, numbered version of an artifact. Structure, statements, classifications and "
                "mappings all belong to a release, not to the artifact."),
    ("Source Structure", "The artifact's own hierarchy for one release - chapters, sections, clauses. "
                         "Folders, not text."),
    ("Source Statement", "The regulatory sentence itself, captured verbatim under a structure node. "
                         "Also called a framework statement."),
    ("Source Classification", "A release's own labelling scheme for its statements - Mandatory vs "
                              "Recommended, Level 1/2/3."),
    ("Practice", "An atomic, assessable thing the organisation does. Global - reusable across "
                 "artifacts, authorities and releases. Code is auto-generated as PR-nnn."),
    ("Obligation", "What a practice must deliver, of a specific type, with its evidence "
                   "specification. Global, and named rather than coded."),
    ("Obligation Type", "One of State, Execution, Assurance, Event Response, Constraint, Retention or "
                        "Evidence. Determines which typed detail fields the form asks for."),
    ("Evidence specification", "A row on an obligation naming an evidence type, its retention period "
                               "and remarks - what proof the obligation produces."),
    ("Mapping", "A link between two repository records - practice to statement, or obligation to "
                "practice and release. Mappings are what make traceability work in both directions."),
    ("Event / Event Domain", "A tracked occurrence and the family it belongs to. Raising an event "
                             "generates a checklist."),
    ("Event Checklist", "The set of assurance items generated when an event is raised, one per "
                        "event-driven assurance obligation naming that event."),
    ("Trigger Mode", "On an Assurance obligation: Scheduled (runs on a frequency) or Event driven "
                     "(runs each time an event occurs)."),
    ("Due Within", "An interval, not a date. Applied to each event occurrence to calculate that "
                   "item's due date."),
    ("SLA", "How long a process has before breach, with warning and escalation thresholds expressed "
            "as percentages of the elapsed allowance."),
    ("Time Basis", "Whether an SLA counts Business Hours, Business Days or Calendar Days. Business "
                   "bases honour the working calendar."),
    ("Maker", "The user who raises a change."),
    ("Checker", "The user who approves, rejects or sends back a change. On a properly configured "
                "module, never the same person as the maker."),
    ("Change Request", "A parked change awaiting a checker's decision. The live record is unchanged "
                       "until it is approved."),
    ("Auto Approved", "A change applied immediately because the module does not require approval, or "
                      "the user is permitted to self-approve."),
    ("Sent Back", "A change returned to its maker for correction, with mandatory checker comments."),
    ("Lifecycle (assurance)", "Draft, Review, Approved, Published, Retired - the states an assurance "
                              "metadata master moves through. Separate from Status."),
    ("Soft delete / Inactive / Retired", "Deactivation, not deletion. The record stops appearing in "
                                         "lookups and new mappings; its data and audit history remain "
                                         "and it can be reactivated."),
    ("Audit trace", "The append-only record of who changed what, from which value to which value, and "
                    "when. Cannot be edited by anyone."),
], [2300, 7060])

doc.add_page_break()

heading(doc, "Document control", 1)
table(doc, ["Item", "Detail"], [
    ("Document", "GRAC Control Management - User Manual v3.0"),
    ("Owner", "GRAC Product Team"),
    ("Applies to", "The Control Management module (Repository Management, Assurance Management, "
                   "Change Management, Access Administration, Audit Traceability)"),
    ("Review cycle", "Reviewed on each functional release of the module"),
    ("Classification", "Confidential - Internal Use"),
], [2300, 7060])
para(doc, "Screenshot placeholders are marked throughout. Replace each with a capture from the "
          "deployed environment before circulating this manual outside the product team.",
     italic=True, color=MUTED, size=10)

doc.save(str(OUT))
print(f"Written: {OUT}")
