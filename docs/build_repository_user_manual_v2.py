"""
Builds GRAC_RepositoryManagement_UserManual_v2.docx.

Version 2.0 of the Repository Management user manual.  Carries forward every
section of the 28-Jun-2026 v1.0 manual and adds the modules delivered since:
Obligation Master + the 7-type obligation taxonomy, Assurance Management,
event-driven assurance (Raise Event / Event Checklists), SLA Master, and the
Bulk / Single-Form upload paths.

House style matches build_user_manual.py (Calibri, navy/blue headings, shaded
table headers, callout boxes, screenshot placeholders).

Run:  python docs/build_repository_user_manual_v2.py
"""

from pathlib import Path
from docx import Document
from docx.shared import Inches, Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_CELL_VERTICAL_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn

OUT = Path(__file__).with_name("GRAC_RepositoryManagement_UserManual_v2.docx")

NAVY = "0B2545"; BLUE = "2E74B5"; DARK_BLUE = "1F4D78"; MUTED = "667085"
HEADER_FILL = "E8EEF5"; LIGHT_FILL = "F4F6F9"; WARN_FILL = "FFF8E8"; NEW_FILL = "EAF4EC"

PAGE_W = 9360  # usable width in dxa with 1" margins


# ---------------------------------------------------------------------------
# Low-level docx helpers
# ---------------------------------------------------------------------------

def set_cell_shading(cell, fill):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = tcPr.find(qn("w:shd"))
    if shd is None:
        shd = OxmlElement("w:shd"); tcPr.append(shd)
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


def set_table_geometry(table, widths):
    table.alignment = WD_TABLE_ALIGNMENT.LEFT
    table.autofit = False
    tblPr = table._tbl.tblPr
    tblW = tblPr.find(qn("w:tblW"))
    if tblW is None:
        tblW = OxmlElement("w:tblW"); tblPr.append(tblW)
    tblW.set(qn("w:w"), str(sum(widths))); tblW.set(qn("w:type"), "dxa")
    tblInd = tblPr.find(qn("w:tblInd"))
    if tblInd is None:
        tblInd = OxmlElement("w:tblInd"); tblPr.append(tblInd)
    tblInd.set(qn("w:w"), "120"); tblInd.set(qn("w:type"), "dxa")
    for col, width in zip(table._tbl.tblGrid.gridCol_lst, widths):
        col.set(qn("w:w"), str(width))
    for row in table.rows:
        for cell, width in zip(row.cells, widths):
            tcPr = cell._tc.get_or_add_tcPr()
            tcW = tcPr.find(qn("w:tcW"))
            if tcW is None:
                tcW = OxmlElement("w:tcW"); tcPr.append(tcW)
            tcW.set(qn("w:w"), str(width)); tcW.set(qn("w:type"), "dxa")
            set_cell_margin(cell)
            cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER


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


def step(doc, text):
    p = doc.add_paragraph(style="List Number"); style_para(p, after=4)
    set_font(p.add_run(text), size=11)


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
# Reusable text blocks
# ---------------------------------------------------------------------------

CRUD_LINES = [
    "Add: Click 'Add' on the page heading. The dialog opens. Fill the required fields and click Save. "
    "The record is either created directly or submitted as a Change Request, depending on the Approval "
    "Workflow for the module.",
    "Edit: Open the 3-dot menu on the row and choose Edit. The dialog pre-fills with the current values. "
    "Update and Save.",
    "View: Open the 3-dot menu on the row and choose View. The dialog opens read-only.",
    "Inactive: Open the 3-dot menu on the row and choose Inactive. Confirm the warning. Historical data and "
    "child records remain intact; the record no longer participates in lookups or new mappings.",
]

AUDIT_STD = ("Every Add / Edit / Inactive event writes an audit_trace_event row plus field-level "
             "audit_trace_detail rows (Old Value to New Value). Both the header and the field rows are "
             "visible in the Audit Traceability menu, filterable by entity type, change type and date.")

FIELD_HEADERS = ["Field", "Required", "Description"]
FIELD_WIDTHS = [2300, 1200, 5860]


def screen(doc, number, title, purpose, when, fields, rules,
           approval=None, audit=AUDIT_STD, crud=True, shot=None, extra_actions=None):
    """Render one screen section in the standard v1.0 layout."""
    heading(doc, f"{number} {title}", 2)
    heading(doc, "Purpose", 3); para(doc, purpose)
    if when:
        heading(doc, "When to use", 3); para(doc, when)
    if fields:
        heading(doc, "Fields", 3)
        table(doc, FIELD_HEADERS, fields, FIELD_WIDTHS)
    if crud:
        heading(doc, "Add / Edit / View / Inactive", 3)
        for line in CRUD_LINES:
            para(doc, line, after=4)
    if extra_actions:
        for line in extra_actions:
            para(doc, line, after=4)
    if rules:
        heading(doc, "Important business rules", 3)
        for rule in rules:
            bullet(doc, rule)
    if approval:
        heading(doc, "Approval behaviour", 3); para(doc, approval)
    if audit:
        heading(doc, "Audit behaviour", 3); para(doc, audit)
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
set_font(hdr.add_run("GRAC | Repository Management User Manual v2.0"), size=9, color=MUTED)

ftr = sec.footer.paragraphs[0]
ftr.alignment = WD_ALIGN_PARAGRAPH.CENTER
style_para(ftr, after=0, line=1)
set_font(ftr.add_run("Confidential - Internal Use"), size=9, color=MUTED)


# ---------------------------------------------------------------------------
# Cover
# ---------------------------------------------------------------------------

para(doc, "GRAC", bold=True, color=BLUE, size=14, after=44)
para(doc, "REPOSITORY MANAGEMENT", bold=True, color=NAVY, size=28, after=4)
para(doc, "User Manual", color=DARK_BLUE, size=18, after=10)
para(doc, "Continuous Compliance Assured - regulatory intelligence repository, obligations, "
          "assurance, change management and audit traceability", color=MUTED, size=12, after=30)

table(doc, ["Document", "Details"], [
    ("Title", "GRAC Repository Management - User Manual"),
    ("Version", "2.0"),
    ("Module", "Repository Management (ControlManagement)"),
    ("Prepared for", "GRAC Repository Administrators, Compliance Reviewers, Approvers, Assurance Owners"),
    ("Prepared by", "GRAC Product Team"),
    ("Date", "August 2026"),
    ("Status", "Released"),
    ("Classification", "Confidential - Internal Use"),
], [2500, 6860])

heading(doc, "Change History", 2)
table(doc, ["Version", "Date", "Author", "Summary of Changes"], [
    ("1.0", "28-Jun-2026", "GRAC Product Team",
     "Initial release covering Repository Management, Change Management, Access Administration and "
     "Audit Traceability."),
    ("2.0", "15-Aug-2026", "GRAC Product Team",
     "Adds Obligation Master and the 7-type obligation taxonomy, Assurance Management metadata masters "
     "and lifecycle, SLA Master, event-driven assurance (Raise Event and Event Checklists), and the Bulk "
     "and Single-Form upload paths. Existing chapters refreshed and renumbered."),
], [1000, 1300, 1900, 5160])

doc.add_page_break()

heading(doc, "Table of Contents", 1)
toc_field(doc)
para(doc, "Right-click and choose 'Update Field' to populate the table of contents.",
     italic=True, color=MUTED, size=10)
para(doc, "Tip: in Microsoft Word press Ctrl+A then F9 to refresh the table of contents and page numbers.",
     italic=True, color=MUTED, size=10)
doc.add_page_break()


# ---------------------------------------------------------------------------
# 1. Introduction
# ---------------------------------------------------------------------------

heading(doc, "1. Introduction", 1)

heading(doc, "1.1 Purpose of Repository Management", 2)
para(doc, "Repository Management is the GRAC module that holds the organisation's regulatory intelligence "
          "in one structured place. It captures who issues a regulation (the Authority), what the regulation "
          "is (the Artifact), which version is current (the Release), how the regulation is structured "
          "internally (Source Classification and Source Structure), the actual regulatory text (Source "
          "Statements), the assessable practices the organisation maintains against those statements "
          "(Practices), and the obligations that say what must actually be done, verified, retained or never "
          "breached.")
para(doc, "Version 2.0 extends the module beyond the repository itself. Obligations are now classified into "
          "seven atomic types, each with its own structured detail. Assurance Management supplies the reusable "
          "metadata that assurance activities are built from. Event-driven assurance turns an obligation into "
          "a checklist the moment a tracked event occurs. Bulk and single-form uploads let an administrator "
          "load a whole release without typing it row by row.")
para(doc, "Every change goes through a configurable maker-checker workflow in Change Management. Every record "
          "change is captured immutably in Audit Traceability. Access Administration controls who can see, "
          "add, edit, approve or retire each module.")

heading(doc, "1.2 Scope of the Module", 2)
bullet(doc, "Regulatory repository: Authority to Artifact to Release to Source Structure to Source Statements.")
bullet(doc, "Practice library: Practices mapped back to Source Statements.")
bullet(doc, "Obligations: Obligation Master, the 7-type obligation taxonomy, evidence specifications, and "
            "Practice-Obligation mapping.")
bullet(doc, "Assurance Management: categories, scoring models, severity, gap categories, workflow templates, "
            "question types, sampling models, frequency types, report templates, starter templates, SLA "
            "Master and version history.")
bullet(doc, "Event-driven assurance: raising an event occurrence and completing the checklist it generates.")
bullet(doc, "Data upload: multi-sheet bulk workbook and per-entity single-form upload.")
bullet(doc, "Workflow: Approvals queue and Approval Workflow configuration, including bundled approvals.")
bullet(doc, "Administration: Users, Roles, Menus, Role Permissions.")
bullet(doc, "Audit: full field-level traceability of every save, approval, reject, send-back and password event.")

heading(doc, "1.3 User Roles", 2)
table(doc, ["Role", "Typical Responsibilities", "Default Permissions"], [
    ("CM_ADMIN", "Configures the system, onboards authorities/artifacts, manages users, roles, menus, role "
                 "permissions, approval workflows, assurance metadata and bulk uploads.",
     "Full access to all modules (View, Add, Edit, Inactive, Approve, Reject)."),
    ("CM_REVIEWER", "Reviews repository and obligation content for completeness and correctness.",
     "View on all modules."),
    ("CM_APPROVER", "Acts as checker for maker-checker change requests on the regulatory chain and on impact "
                    "/ change events; publishes assurance metadata.",
     "View on all modules. Approve / Reject on Change Management, Changes and Impact Analysis."),
    ("CM_USER", "General read-only user (extend via Role Permission Management as needed).",
     "View only by default."),
], [1500, 4200, 3660])
callout(doc, "Note", "Bulk Upload requires Add permission on every repository area it writes to, so in "
                     "practice only CM_ADMIN can use it. Single-Form Upload is gated per entity, so a user "
                     "who may add Source Statements can upload statements without gaining rights over "
                     "Authorities.")

heading(doc, "1.4 High-level Process Flow", 2)
for text in [
    "Admin defines Authority, then Artifact, then Release.",
    "Admin (or maker) adds Source Classifications and Source Structure inside the Release.",
    "Maker captures Source Statements under the right structure nodes - by hand or by Single-Form Upload.",
    "Maker creates Practices and links them to statements via Practices - Statement Mapping.",
    "Maker creates Obligations in the Obligation Master, assigns each one a type, and fills the typed detail.",
    "Maker maps obligations to Practice and Release through Practices - Obligation Mapping.",
    "Admin configures Assurance Management metadata and SLA Master once; it is reused by every assurance.",
    "When a tracked event occurs, a user raises the event and the system generates the assurance checklist.",
    "Maker submits any change; the workflow either auto-approves, or routes to a checker via Change Management.",
    "Every change is recorded in Audit Traceability with old and new values.",
]:
    step(doc, text)

heading(doc, "1.5 What is New in Version 2.0", 2)
table(doc, ["Area", "What changed", "Where to read"], [
    ("Obligation Master", "Obligations are now a reusable master with their own screen, separated from the "
                          "Practice-Release mapping.", "Chapter 4"),
    ("Obligation taxonomy", "Every obligation is classified as one of seven atomic types, each with a "
                            "dedicated detail form.", "Sections 4.3 - 4.4"),
    ("Evidence links", "Reusable evidence specifications can be attached to any obligation.", "Section 4.5"),
    ("Assurance Management", "Eleven metadata masters plus a Draft-to-Published lifecycle.", "Chapter 5"),
    ("SLA Master", "Process and classification SLA definitions driving warnings and escalation.",
     "Section 5.14"),
    ("Event-driven assurance", "Raise Event and Event Checklists screens.", "Chapter 6"),
    ("Data upload", "Multi-sheet Bulk Upload and per-entity Single-Form Upload.", "Chapter 7"),
    ("Bundled approvals", "A composite obligation save is approved or rejected as one unit.", "Section 8.5"),
], [1900, 5060, 2400])


# ---------------------------------------------------------------------------
# 2. Login and Navigation
# ---------------------------------------------------------------------------

heading(doc, "2. Login and Navigation", 1)

heading(doc, "2.1 Logging In", 2)
para(doc, "Repository Management is reached at the URL provided by your administrator. Sign in using either "
          "your Login ID or your registered Email plus your password. If your administrator created your "
          "account, you will be issued a default password and you will be required to set a new one on first "
          "sign-in.")
screenshot(doc, "Login screen with the 'Login ID or Email' and 'Password' fields and the 'Forgot Password?' link.")

heading(doc, "2.2 First-login Password Change", 2)
para(doc, "After signing in with the default password, the application redirects you to the Change Password "
          "screen. Enter the default password as the current password, choose a new password (minimum 8 "
          "characters), confirm it, and submit. Until you do, every other page redirects back here. After "
          "this, regular sign-ins skip the redirect.")

heading(doc, "2.3 Forgot Password", 2)
para(doc, "If you have forgotten your password, click 'Forgot Password?' on the login screen. Enter your Login "
          "ID or Email and submit. The administrator is notified and resets your password to the default; you "
          "can then sign in and set a new password through the first-login flow.")

heading(doc, "2.4 Menu Structure", 2)
para(doc, "The left navigation rail groups menus by domain. Only menus you have View permission for are "
          "rendered; everything else is hidden.")
table(doc, ["Group", "Menu Items"], [
    ("Repository Management", "Authority - Artifacts - Releases - Source Classification - Source Structure - "
                              "Source Statements - Practices - Practices - Statement Mapping"),
    ("Obligation Management", "Obligation Master - Practices - Obligation Mapping"),
    ("Assurance Management", "Assurance Categories - Scoring Models - Observation Severity - Gap Categories - "
                             "Workflow Templates - Question Types - Sampling Models - Frequency Types - "
                             "Report Templates - Starter Assurance Templates - SLA Master - Version History"),
    ("Assurance Runtime", "Event Checklists"),
    ("Data Upload", "Bulk Upload - Single-Form Upload"),
    ("Change Management", "Approvals - Approval Workflow"),
    ("Access Administration", "User Management - Role Management - Menu Management - Role Permission Management"),
    ("Audit", "Audit Traceability"),
], [2300, 7060])
callout(doc, "Active highlight", "The currently selected menu is highlighted in the sidebar; the breadcrumb "
                                 "above the grid mirrors that selection.")

heading(doc, "2.5 Common Grid Features", 2)
para(doc, "Every Repository Management screen uses a consistent grid layout so once you learn one, you know "
          "them all.")
table(doc, ["Feature", "Where it lives", "What it does"], [
    ("Search box", "Top toolbar", "Free-text search over the most relevant text columns."),
    ("Status filter", "Top toolbar", "Restrict the grid to a single status (Active, Inactive, Draft, etc.)."),
    ("Context filters", "Top toolbar", "Authority / Artifact / Release filters when the area supports drill-down."),
    ("Clear filters", "Top toolbar", "One-click reset of search, status and context filters."),
    ("Refresh", "Top toolbar", "Re-runs the current query."),
    ("Add", "Page heading", "Opens the Add dialog (visible only if you have Add permission)."),
    ("3-dot action menu", "Last column", "Per-row actions: View, Edit, Inactive, Approve, Reject, Reset "
                                         "Password, and area-specific actions, shown only when you have the "
                                         "right permission."),
    ("Pagination", "Below the grid", "First / Previous / Page X of Y / Next / Last, plus a Rows per page "
                                     "selector with 10, 25, 50 and 100. Total record count is displayed "
                                     "alongside."),
], [1700, 1900, 5760])
screenshot(doc, "Typical Repository grid: toolbar, table headers, 3-dot action menu, pagination footer.")


# ---------------------------------------------------------------------------
# 3. Repository Management
# ---------------------------------------------------------------------------

heading(doc, "3. Repository Management", 1)
para(doc, "Each section below documents one menu under the Repository Management group. The fields, business "
          "rules and approval/audit behaviour reflect the currently-Active build.")

screen(doc, "3.1", "Authority",
       "Captures the regulator, supervisor, standards body or internal owner that issues regulatory artifacts "
       "(for example: RBI, SEBI, IRDAI, ISO, PCI SSC, an internal policy committee).",
       "Add an Authority once per issuing body. Authorities are the top of the regulatory hierarchy and rarely "
       "change once created.",
       [("Code", "Yes", "Short unique identifier (e.g. RBI, SEBI). Used in lookups."),
        ("Name", "Yes", "Official authority name."),
        ("Description", "No", "Free-text background."),
        ("Jurisdiction", "No", "Country / region the authority governs."),
        ("Website", "No", "Reference URL."),
        ("Status", "Yes", "Active or Inactive.")],
       ["Code is unique across all authorities.",
        "Display Order is auto-generated on Add as MAX(display_order) + 1 across the authority table.",
        "Inactivating an Authority does not delete its Artifacts; it simply removes the Authority from active "
        "lookups."],
       approval="If an Approval Workflow row exists for 'authorities' with Approval Required = Yes, saves "
                "create a Change Request and are applied only after a checker approves (or after "
                "auto-approval, see Chapter 8).",
       shot="Add Authority dialog showing Code, Name, Jurisdiction, Website and Status fields.")

screen(doc, "3.2", "Artifacts",
       "Captures a specific regulatory artifact issued by an Authority - for example a circular, master "
       "direction, standard, framework, or guideline.",
       "Add an Artifact whenever an Authority publishes a new regulatory instrument that you need to maintain "
       "in the repository.",
       [("Authority", "Yes", "Issuing Authority (drill-down from Authority grid pre-selects this)."),
        ("Code", "Yes", "Short unique identifier (e.g. PCI-DSS-4.0)."),
        ("Name", "Yes", "Official artifact name."),
        ("Category", "Yes", "Classification (Circular, Standard, Framework, etc.)."),
        ("Description", "No", "Free-text summary."),
        ("Industries", "No", "Industries the artifact applies to."),
        ("Jurisdictions", "No", "Geographies the artifact applies to."),
        ("Status", "Yes", "Active or Inactive.")],
       ["Code is unique across all artifacts (across all authorities).",
        "Display Order is auto-generated per Authority as MAX(display_order) + 1.",
        "From the Authority grid you can navigate directly to its Artifacts using the row's drill-down action."],
       approval="Default workflow assumes Approval Required = Yes for regulatory artifacts. Without an "
                "explicit workflow row, every Add/Edit/Inactive becomes a Pending Approval in Change "
                "Management.")

screen(doc, "3.3", "Releases",
       "Captures a published version of an Artifact. Releases are the unit of version control - every Source "
       "Statement, Obligation mapping and Source Classification is anchored to a Release.",
       "Add a Release whenever an Authority publishes a new version of an Artifact (amendments, master "
       "directions, addenda).",
       [("Artifact", "Yes", "Parent Artifact."),
        ("Version", "Yes", "Version label (e.g. 4.0, 2024-Q1, v2.1)."),
        ("Effective Date", "No", "Date the version becomes effective."),
        ("End Date", "No", "Date the version is superseded (leave blank if current)."),
        ("Release Notes", "No", "Summary of what changed in this release."),
        ("Status", "Yes", "Draft, Active or Retired.")],
       ["(Artifact, Version) must be unique.",
        "Display Order is auto-generated per Artifact as MAX(display_order) + 1.",
        "Retiring a Release does not delete its Source Statements or Obligations; it only freezes the version."],
       approval="Same workflow defaults as Artifacts. Maker-checker recommended for new releases of regulated "
                "frameworks.")

screen(doc, "3.4", "Source Classification",
       "Defines the classification scheme used inside a Release to label Source Statements (e.g. Principle, "
       "Control, Requirement, Sub-Requirement, Implementation Note). Classifications are release-scoped - "
       "different releases can have completely different schemes.",
       "Add classifications for a Release before capturing its Source Statements so each statement can be "
       "tagged correctly.",
       [("Release", "Yes", "Release the classification belongs to."),
        ("Classification Scheme", "No", "Optional grouping (e.g. PCI section types)."),
        ("Classification Name", "Yes", "Display label (e.g. Principle, Sub-Requirement)."),
        ("Description", "No", "Free-text explanation."),
        ("Status", "Yes", "Active or Inactive.")],
       ["Classification Code is auto-derived from the Name when saved.",
        "(Release, Code) must be unique - you cannot have two classifications with the same code inside the "
        "same Release.",
        "Inactivating a classification leaves any existing tagged statements alone, but new statements cannot "
        "pick that classification."],
       approval="Inherits the Release workflow default.")

screen(doc, "3.5", "Source Structure",
       "Captures the native hierarchy of a Release - chapters, sections, sub-sections - exactly as published. "
       "The structure is a tree: each node may have one parent and any number of children.",
       "Add the structure once per Release, before (or as) you capture the Source Statements. The hierarchy "
       "preserves the original document layout for traceability.",
       [("Release", "Yes", "Release this node belongs to."),
        ("Parent Node", "No", "If blank, the node is a root; otherwise it is a child of the chosen parent."),
        ("Node Type", "Yes", "Pick from the configured Node Type list (Chapter, Section, Sub-section...)."),
        ("Node Reference", "Yes", "The reference label exactly as published (e.g. '3.2.1')."),
        ("Node Title", "Yes", "The heading text."),
        ("Description", "No", "Optional commentary."),
        ("Status", "Yes", "Active or Retired.")],
       ["(Release, Node Reference) is unique.",
        "Parent must belong to the same Release.",
        "Display Order is auto-generated within the parent (or within the Release for root nodes).",
        "Only leaf nodes (no active children) can be mapped to Practices via 'Practices - Statement Mapping'."],
       approval="Inherits the Release workflow default.",
       extra_actions=["To add a child node, open the 3-dot menu on the parent row and choose 'Add Child Node' "
                      "- the dialog pre-fills the Release and Parent."],
       shot="Source Structure tree grid with expand/collapse triangles and 3-dot menu showing 'Add Child Node'.")

screen(doc, "3.6", "Source Statements",
       "Captures the actual regulatory text under a Source Structure node. Statements are the canonical record "
       "of what the regulator wrote - the Practice library is then mapped to these statements for compliance.",
       "Add a Source Statement for every regulatory clause that has assessable content. Statements that are "
       "pure headings can be modelled as Source Structure nodes instead.",
       [("Release", "Yes", "Release the statement belongs to."),
        ("Source Structure", "Yes", "The structure node the statement sits under (pick from the tree)."),
        ("Statement Classification", "No", "Pick from the Release's Source Classifications."),
        ("Statement Reference", "Yes", "Reference as published (e.g. '3.2.1.a'). Unique inside the Release."),
        ("Statement Title", "No", "Optional short label."),
        ("Statement Text", "Yes", "The full text of the regulatory clause."),
        ("Statement Type", "No", "Free-text type label."),
        ("Remarks", "No", "Internal commentary."),
        ("Status", "Yes", "Active or Retired.")],
       ["(Release, Statement Reference) is unique - a clear error message is shown if you try to duplicate.",
        "The chosen Source Structure node must belong to the chosen Release.",
        "The chosen Statement Classification must belong to the chosen Release.",
        "Display Order is auto-generated within the Source Structure node.",
        "Large releases are far faster to load through Single-Form Upload (see Chapter 7)."],
       approval="Inherits the Release workflow default - typically maker-checker.")

screen(doc, "3.7", "Practices",
       "Captures the atomic, assessable compliance practices the organisation maintains. Practices are "
       "reusable across releases - they sit in their own library and are mapped to Source Statements via "
       "Practices - Statement Mapping.",
       "Add a Practice whenever you identify a repeatable control / activity the organisation performs to "
       "satisfy one or more regulatory statements.",
       [("Practice Code", "Yes", "Short unique identifier."),
        ("Practice Name", "Yes", "Display name."),
        ("Description", "Yes", "What the practice does."),
        ("Objective", "No", "Why the practice exists / outcome."),
        ("Keywords", "No", "Comma-separated search keywords."),
        ("Status", "Yes", "Active or Retired.")],
       ["Practice Code is unique.",
        "Practices are independent of Release - the same practice can be mapped to many statements across "
        "many releases.",
        "Retiring a Practice keeps existing mappings; only new mappings are blocked.",
        "When adding a Practice the form shows possible duplicates ('similar practices') so the same "
        "expectation is not captured twice."],
       approval="Default regulatory workflow applies - Practices are treated as a maker-checker entity.")

screen(doc, "3.8", "Practices - Statement Mapping",
       "Captures which Practices satisfy which Source Statements. This is the join between the regulatory text "
       "and the organisation's control framework - the basis for every traceability and gap-analysis report.",
       "Use this menu when you need to align one or more Practices to a Source Statement (or, equivalently, to "
       "a leaf Source Structure node).",
       [("Source Structure Node", "Yes", "Leaf node carrying the regulatory text (parent nodes cannot be mapped)."),
        ("Practices", "Yes", "One or more Practices that satisfy the statement (multi-select)."),
        ("Status", "Yes", "Active or Inactive.")],
       ["Only leaf source structure nodes can be mapped - the system blocks mapping a parent node and shows a "
        "clear error.",
        "A node can be mapped to many practices; a practice can be mapped to many nodes.",
        "Inactivating a mapping does not delete the practice or the statement; only the link is removed from "
        "active lookups."],
       approval="Inherits the regulatory maker-checker default.")


# ---------------------------------------------------------------------------
# 4. Obligations
# ---------------------------------------------------------------------------

doc.add_page_break()
heading(doc, "4. Obligations", 1)
callout(doc, "New in 2.0", "The whole of Chapter 4 is new. In version 1.0 an obligation was a single "
                           "free-text record attached to a Practice and a Release. It is now a reusable "
                           "master, classified into one of seven atomic types, each with structured fields.",
        fill=NEW_FILL)

heading(doc, "4.1 The Obligation Model", 2)
para(doc, "An obligation answers the question 'what does this regulation actually require us to do?'. GRAC "
          "splits that into three separate things so each can be reused independently:")
table(doc, ["Layer", "What it holds", "Screen"], [
    ("Obligation Master", "The obligation itself - name, type, frequency, retention, keywords. Reusable "
                          "across practices and releases.", "Obligation Master"),
    ("Typed detail", "The structured fields specific to the obligation's type (see 4.4).",
     "Obligation Master form, Typed Detail tab"),
    ("Mapping", "Which Practice, in which Release, this obligation applies to.",
     "Practices - Obligation Mapping"),
], [2100, 4800, 2460])
callout(doc, "Why this matters", "The same obligation - 'review privileged access quarterly' - often appears "
                                 "in several regulations. Holding it once and mapping it many times means one "
                                 "edit updates every place it is used, and the evidence you collect satisfies "
                                 "all of them at once.")

heading(doc, "4.2 Obligation Master", 2)
heading(doc, "Purpose", 3)
para(doc, "The reusable library of obligations. Every obligation is created here first, then mapped to "
          "practices and releases.")
heading(doc, "Fields", 3)
table(doc, FIELD_HEADERS, [
    ("Obligation Name", "Yes", "Short, action-oriented name (e.g. 'Quarterly privileged access review')."),
    ("Obligation Type", "Yes", "One of the seven types in 4.3. Determines which typed detail form opens."),
    ("Execution Frequency", "No", "Picked from the Frequency master - not free-typed."),
    ("Retention Period", "No", "How long the resulting evidence must be kept."),
    ("Keywords", "No", "Comma-separated search terms."),
    ("Remarks", "No", "Internal commentary."),
    ("Status", "Yes", "Active or Inactive."),
], FIELD_WIDTHS)
heading(doc, "Add / Edit / View / Inactive", 3)
for line in CRUD_LINES:
    para(doc, line, after=4)
heading(doc, "Important business rules", 3)
bullet(doc, "An obligation must have a type before its typed detail can be filled in.")
bullet(doc, "Changing the type of an obligation that already has typed detail retires the old detail row and "
            "starts a new one - the previous values stay in the audit trail.")
bullet(doc, "While you type the Obligation Name the form lists similar existing obligations so duplicates are "
            "avoided.")
bullet(doc, "The grid shows Evidence Count and Mapping Count so you can see at a glance how widely an "
            "obligation is used before editing it.")
heading(doc, "Approval behaviour", 3)
para(doc, "The Obligation Master is a maker-checker entity. Saving the master together with its type, typed "
          "detail and evidence links produces a bundled change request - see section 8.5.")
heading(doc, "Audit behaviour", 3)
para(doc, AUDIT_STD)
screenshot(doc, "Obligation Master form showing Obligation Name, Obligation Type, Execution Frequency, "
                "Retention Period and the typed detail panel below.")

heading(doc, "4.3 Obligation Types", 2)
para(doc, "Every obligation is exactly one of the following seven types. Choosing the right type is the most "
          "important decision on the form, because it decides what you are asked to capture next.")
table(doc, ["Type", "Answers the question", "Example"], [
    ("State", "What must be true, and stay true?", "Password length must be at least 12 characters."),
    ("Execution", "What must be done, and when?", "Reconcile the customer ledger monthly."),
    ("Assurance", "What must be verified, and how?", "Internal audit tests access recertification quarterly."),
    ("Event Response", "If X happens, what must follow, and within what SLA?",
     "Report a data breach to the regulator within 6 hours."),
    ("Constraint", "What must never happen?", "Customer data must not be stored outside India."),
    ("Evidence", "What proves it was done?", "Signed quarterly access review sheet."),
    ("Retention", "What must be kept, and for how long?", "Retain KYC records for 5 years after closure."),
], [1500, 3760, 4100])
callout(doc, "Rule of thumb", "If the obligation describes a condition, it is State. If it describes an "
                              "activity on a calendar, it is Execution. If it describes checking someone "
                              "else's activity, it is Assurance. If it starts with 'if' or 'on', it is Event "
                              "Response. If it starts with 'must not', it is Constraint.")

heading(doc, "4.4 Typed Obligation Detail", 2)
para(doc, "Once a type is assigned, the Typed Detail form opens with the fields for that type. All typed "
          "detail is reached from the Obligation Master form; there is no separate menu.")

heading(doc, "State", 3)
table(doc, FIELD_HEADERS, [
    ("Attribute", "Yes", "The thing being constrained (e.g. 'password length')."),
    ("Operator", "Yes", "Comparison - at least, at most, equals, between, etc."),
    ("Value", "Yes", "The threshold or required value."),
    ("Unit", "No", "Unit of the value (characters, days, percent...)."),
    ("Tolerance", "No", "Any permitted deviation."),
    ("Remarks", "No", "Internal commentary."),
], FIELD_WIDTHS)

heading(doc, "Execution", 3)
table(doc, FIELD_HEADERS, [
    ("Action", "Yes", "What must be performed."),
    ("Execution Frequency", "No", "From the Frequency master."),
    ("Trigger Condition", "No", "What starts the clock, if it is not a plain schedule."),
    ("Responsible Party", "No", "Role or team accountable for performing it."),
    ("Due Within", "No", "Deadline once triggered."),
    ("Remarks", "No", "Internal commentary."),
], FIELD_WIDTHS)

heading(doc, "Assurance", 3)
table(doc, FIELD_HEADERS, [
    ("Verification Method", "Yes", "How the check is performed (sample test, full population, attestation...)."),
    ("Scope", "No", "What the check covers."),
    ("Assurance Frequency", "No", "From the Frequency master."),
    ("Assurance Party", "No", "Who performs the verification - typically a second or third line function."),
    ("Remarks", "No", "Internal commentary."),
], FIELD_WIDTHS)
callout(doc, "Important", "Assurance-type obligations are what event-driven assurance turns into checklist "
                          "items. If an obligation has no Assurance detail, raising an event will not "
                          "generate a checklist row for it. See Chapter 6.")

heading(doc, "Event Response", 3)
table(doc, FIELD_HEADERS, [
    ("Trigger Event", "Yes", "The event that starts the obligation."),
    ("Response Action", "Yes", "What must happen in response."),
    ("SLA Value / SLA Unit", "No", "The deadline, e.g. 6 / Hours."),
    ("Escalation Path", "No", "Who is informed if the SLA is missed."),
    ("Remarks", "No", "Internal commentary."),
], FIELD_WIDTHS)

heading(doc, "Constraint", 3)
table(doc, FIELD_HEADERS, [
    ("Prohibited Condition", "Yes", "What must never occur."),
    ("Scope", "No", "Where the prohibition applies."),
    ("Exception Policy", "No", "Whether exceptions exist and how they are approved."),
    ("Remarks", "No", "Internal commentary."),
], FIELD_WIDTHS)

heading(doc, "Retention", 3)
table(doc, FIELD_HEADERS, [
    ("Retained Object", "Yes", "What must be preserved."),
    ("Minimum Retention", "No", "Value and unit - the floor."),
    ("Maximum Retention", "No", "Value and unit - the ceiling, where over-retention is itself a breach."),
    ("Disposal Policy", "No", "How the object must be destroyed at end of life."),
    ("Remarks", "No", "Internal commentary."),
], FIELD_WIDTHS)
callout(doc, "Note", "The Evidence type has no separate detail table. Evidence obligations are captured "
                     "through the evidence specification and attached to other obligations as links - see 4.5.")

heading(doc, "4.5 Evidence Specifications and Links", 2)
para(doc, "An evidence specification describes a proof artefact - what it is, what form it takes, and who "
          "produces it. Because the same proof often satisfies several obligations, evidence is held once and "
          "linked.")
bullet(doc, "Evidence types come from the Evidence Type master and cannot be free-typed.")
bullet(doc, "Any obligation of any type can have one or more evidence specifications attached.")
bullet(doc, "Attach and detach are performed from the Evidence Spec panel on the Obligation Master form.")
bullet(doc, "Detaching an evidence link never deletes the evidence specification itself - it only removes the "
            "association.")
bullet(doc, "Duplicate evidence types under the same obligation are rejected.")

heading(doc, "4.6 Practices - Obligation Mapping", 2)
heading(doc, "Purpose", 3)
para(doc, "Declares that a given obligation applies to a given Practice within a given Release. This is what "
          "makes an obligation operational - until it is mapped, it sits in the library unused.")
heading(doc, "Fields", 3)
table(doc, FIELD_HEADERS, [
    ("Practice", "Yes", "The Practice the obligation attaches to."),
    ("Release", "Yes", "The Release the mapping applies to."),
    ("Obligation", "Yes", "One or more obligations from the Obligation Master (multi-select)."),
    ("Status", "Yes", "Active or Inactive."),
], FIELD_WIDTHS)
heading(doc, "Important business rules", 3)
bullet(doc, "Both Practice and Release are mandatory - an obligation cannot be mapped to a practice in general.")
bullet(doc, "The grid groups by Obligation; expand a row to see all its Practice/Release mappings.")
bullet(doc, "The same obligation can be mapped to many practices and many releases.")
bullet(doc, "Inactivating a mapping leaves the obligation and the practice untouched.")
heading(doc, "Audit behaviour", 3)
para(doc, AUDIT_STD)


# ---------------------------------------------------------------------------
# 5. Assurance Management
# ---------------------------------------------------------------------------

doc.add_page_break()
heading(doc, "5. Assurance Management", 1)
callout(doc, "New in 2.0", "Chapter 5 is new. These screens hold reusable configuration only. Nothing here "
                           "is regulation-specific - you set it up once and every assurance activity in the "
                           "platform draws on it.", fill=NEW_FILL)

heading(doc, "5.1 What Assurance Management Does", 2)
para(doc, "Assurance Management supplies the vocabulary that assurance activities are described in: how "
          "findings are scored, how severe an observation is, what kinds of question an assurance can ask, how "
          "samples are drawn, how often checks run, and what the resulting report looks like. Defining these "
          "centrally means two assurance owners in different departments grade a finding the same way.")

heading(doc, "5.2 The Assurance Metadata Lifecycle", 2)
para(doc, "Unlike repository records, which are simply Active or Inactive, assurance metadata is versioned and "
          "moves through a formal lifecycle. This exists so a scoring model cannot be quietly altered while "
          "assurances are being graded against it.")
table(doc, ["Status", "Meaning", "Available actions"], [
    ("Draft", "Being authored. Freely editable.", "Edit, Submit"),
    ("Review", "Submitted and awaiting a decision.", "Approve, Reject"),
    ("Approved", "Accepted but not yet in use.", "Publish"),
    ("Published", "Live. In use by assurance activities.", "Retire"),
    ("Retired", "Withdrawn from use. Retained for history.", "None"),
], [1400, 4300, 3660])
table(doc, ["Action", "Who can do it", "Effect"], [
    ("Submit", "Anyone with Edit on the area", "Draft moves to Review."),
    ("Approve", "Anyone with Approve on the area", "Review moves to Approved."),
    ("Reject", "Anyone with Approve on the area", "Review returns to Draft. Comments are mandatory."),
    ("Publish", "Anyone with Approve on the area", "Approved or Published moves to Published."),
    ("Retire", "Anyone with Approve on the area", "Published moves to Retired."),
], [1400, 2800, 5160])
callout(doc, "Important", "Approved, Published and Retired records cannot be edited in place. The platform "
                          "refuses a direct edit with the message 'Approved, Published or Retired records "
                          "cannot be edited directly. Create a new version instead.' A new version is created "
                          "by adding a record with the same Code and the next Version label - see workflow "
                          "11.7.", fill=WARN_FILL)

_ASSURANCE = [
    ("5.3", "Assurance Categories",
     "Groups assurance activities into reusable categories so reporting can roll up consistently.",
     [("Code", "Yes", "Short unique identifier."),
      ("Name", "Yes", "Display name."),
      ("Description", "No", "What belongs in this category."),
      ("Display Order", "No", "Position in dropdowns."),
      ("Version", "Yes", "Version label, incremented when a new version is created."),
      ("Lifecycle Status", "Yes", "Draft / Review / Approved / Published / Retired.")],
     ["Category Code is unique.", "Code and Name are both mandatory."]),

    ("5.4", "Scoring Models",
     "Defines how assurance results are converted into a score or rating.",
     [("Code", "Yes", "Short unique identifier."),
      ("Name", "Yes", "Display name."),
      ("Formula Type", "No", "The calculation family (weighted, average, threshold...)."),
      ("Formula Definition", "No", "The configuration data for the calculation."),
      ("Rating Scale", "No", "The bands the score maps to."),
      ("Pass Threshold", "No", "The score at or above which the assurance passes."),
      ("Version / Lifecycle Status", "Yes", "As described in 5.2.")],
     ["Scoring Model Code is unique.",
      "The formula definition must be configuration data. The platform rejects anything that looks like "
      "executable SQL with the message 'Formula definition must be configuration data, not executable SQL.'"]),

    ("5.5", "Observation Severity",
     "The severity classifications applied to assurance observations and findings.",
     [("Code", "Yes", "Short unique identifier."),
      ("Name", "Yes", "Display name (e.g. Critical, High, Medium, Low)."),
      ("Severity Rank", "No", "Numeric ordering - lower is more severe."),
      ("Colour Code", "No", "Display colour used in dashboards."),
      ("Version / Lifecycle Status", "Yes", "As described in 5.2.")],
     ["Severity Code is unique.",
      "Severity Rank drives sort order and escalation - keep the sequence contiguous."]),

    ("5.6", "Gap Categories",
     "Standard classification of the gaps an assurance can raise, so remediation reporting is consistent.",
     [("Code", "Yes", "Short unique identifier."),
      ("Name", "Yes", "Display name."),
      ("Description", "No", "What kind of gap this covers."),
      ("Display Order", "No", "Position in dropdowns."),
      ("Version / Lifecycle Status", "Yes", "As described in 5.2.")],
     ["Gap Code is unique."]),

    ("5.7", "Workflow Templates",
     "Reusable workflow models with stages, SLA and escalation, applied to assurance activities.",
     [("Code", "Yes", "Short unique identifier."),
      ("Name", "Yes", "Display name."),
      ("Description", "No", "What the workflow is for."),
      ("SLA Hours", "No", "Overall service level for the workflow."),
      ("Escalation Rule", "No", "What happens when the SLA is breached."),
      ("Stages", "No", "The ordered stages the activity passes through."),
      ("Version / Lifecycle Status", "Yes", "As described in 5.2.")],
     ["Workflow Template Code is unique.",
      "The grid shows Stage Count and SLA Hours so templates can be compared at a glance."]),

    ("5.8", "Question Types",
     "The kinds of question an assurance questionnaire may ask, and what shape the answer takes.",
     [("Code", "Yes", "Short unique identifier."),
      ("Name", "Yes", "Display name (e.g. Yes/No, Rating, Free Text)."),
      ("Answer Shape", "No", "The data type the answer is captured as."),
      ("Requires Evidence", "No", "Whether an answer of this type must be backed by evidence."),
      ("Display Order", "No", "Position in dropdowns."),
      ("Version / Lifecycle Status", "Yes", "As described in 5.2.")],
     ["Question Type Code is unique."]),

    ("5.9", "Sampling Models",
     "Reusable sampling methodologies for assurance testing.",
     [("Code", "Yes", "Short unique identifier."),
      ("Name", "Yes", "Display name."),
      ("Description", "No", "When to use this model."),
      ("Methodology", "No", "How the sample is drawn and sized."),
      ("Version / Lifecycle Status", "Yes", "As described in 5.2.")],
     ["Sampling Model Code is unique."]),

    ("5.10", "Frequency Types",
     "Reusable execution frequencies shared by obligations and assurance activities.",
     [("Code", "Yes", "Short unique identifier."),
      ("Name", "Yes", "Display name (Daily, Monthly, Quarterly...)."),
      ("Interval Days", "No", "Nominal number of days between occurrences - drives due-date calculation."),
      ("Display Order", "No", "Position in dropdowns."),
      ("Version / Lifecycle Status", "Yes", "As described in 5.2.")],
     ["Frequency Code is unique.",
      "This is the same master that supplies Execution Frequency and Assurance Frequency on obligations, so "
      "adding a frequency here makes it available across the platform."]),

    ("5.11", "Report Templates",
     "Reusable report layouts for assurance output.",
     [("Code", "Yes", "Short unique identifier."),
      ("Name", "Yes", "Display name."),
      ("Report Scope", "No", "What the report covers."),
      ("Layout Definition", "No", "The template configuration."),
      ("Version / Lifecycle Status", "Yes", "As described in 5.2.")],
     ["Report Template Code is unique."]),

    ("5.12", "Starter Assurance Templates",
     "Ready-to-subscribe bundles that pre-select a category, scoring model, workflow template, sampling model, "
     "frequency and report template, so a new assurance can be stood up in one step.",
     [("Code", "Yes", "Short unique identifier."),
      ("Name", "Yes", "Display name."),
      ("Category", "No", "Assurance Category to apply."),
      ("Scoring Model", "No", "Scoring Model to apply."),
      ("Workflow Template", "No", "Workflow Template to apply."),
      ("Sampling Model", "No", "Sampling Model to apply."),
      ("Frequency Type", "No", "Frequency to apply."),
      ("Report Template", "No", "Report Template to apply."),
      ("Questions", "No", "The starter question set bundled with the template."),
      ("Version / Lifecycle Status", "Yes", "As described in 5.2.")],
     ["Starter Template Code is unique.",
      "Only Published metadata should be referenced by a starter template - referencing a Draft leaves the "
      "bundle incomplete for subscribers."]),
]

for num, title, purpose, fields, rules in _ASSURANCE:
    heading(doc, f"{num} {title}", 2)
    heading(doc, "Purpose", 3); para(doc, purpose)
    heading(doc, "Fields", 3); table(doc, FIELD_HEADERS, fields, FIELD_WIDTHS)
    heading(doc, "Important business rules", 3)
    for rule in rules:
        bullet(doc, rule)
    para(doc, "Lifecycle actions (Submit, Approve, Reject, Publish, Retire) are available from the 3-dot menu "
              "subject to your permissions - see 5.2.", size=10.5, color=MUTED, italic=True)

heading(doc, "5.13 Version History", 2)
para(doc, "A read-only, immutable record of every lifecycle transition across all assurance metadata. Use it "
          "to answer 'which version of this scoring model was live when that assurance was graded?'.")
table(doc, ["Column", "Meaning"], [
    ("Entity Type", "Which assurance master the row belongs to."),
    ("Entity Id", "Identifier of the specific record."),
    ("Version", "Version label at the time of the transition."),
    ("Lifecycle Status", "Status the record moved into."),
    ("Action Code", "The action performed (SUBMIT, APPROVE, REJECT, PUBLISH, RETIRE)."),
    ("Entered By", "Login ID of the actor."),
    ("Entered Dt", "Timestamp of the transition."),
], [2300, 7060])
callout(doc, "Immutability", "Version History rows cannot be edited or deleted. A database trigger rejects "
                             "any UPDATE or DELETE against the table.")

heading(doc, "5.14 SLA Master", 2)
heading(doc, "Purpose", 3)
para(doc, "Defines the service level for a process and severity classification: how long something may take, "
          "when a warning is raised, and when it escalates. SLA Master drives the breach warnings and "
          "escalations you see across the assurance runtime.")
heading(doc, "Fields", 3)
table(doc, FIELD_HEADERS, [
    ("SLA ID", "Auto", "Generated code - read-only on the form."),
    ("Process", "Yes", "The process the SLA governs."),
    ("Classification", "Yes", "The severity or priority class this SLA applies to."),
    ("Duration Value", "Yes", "The numeric duration."),
    ("Duration Unit", "Yes", "Hours or Days."),
    ("Time Basis", "Yes", "Calendar time or working time."),
    ("Warning %", "No", "Percentage of the duration at which a warning is raised (e.g. 80)."),
    ("Escalation %", "No", "Percentage of the duration at which escalation triggers (e.g. 100)."),
    ("Effective From", "No", "Date the SLA takes effect."),
    ("Remarks", "No", "Internal commentary."),
    ("Status", "Yes", "Active or Inactive."),
], FIELD_WIDTHS)
heading(doc, "Important business rules", 3)
bullet(doc, "SLA Master is a simple configuration master - it has no Draft/Publish lifecycle, only Active and "
            "Inactive.")
bullet(doc, "Warning % should be lower than Escalation %; setting them the other way round means the warning "
            "never fires before escalation.")
bullet(doc, "Time Basis matters: a 24-hour calendar SLA and a 24-hour working-time SLA can be days apart.")
heading(doc, "Audit behaviour", 3)
para(doc, AUDIT_STD)


# ---------------------------------------------------------------------------
# 6. Event-Driven Assurance
# ---------------------------------------------------------------------------

doc.add_page_break()
heading(doc, "6. Event-Driven Assurance", 1)
callout(doc, "New in 2.0", "Chapter 6 is new.", fill=NEW_FILL)

heading(doc, "6.1 The Concept", 2)
para(doc, "Some assurance is calendar-driven - check this every quarter. Other assurance is event-driven - "
          "whenever a new server is commissioned, or an employee leaves, or a vendor is onboarded, a set of "
          "checks must be performed on that specific thing.")
para(doc, "Event-driven assurance automates the second case. You record that an event happened; GRAC looks up "
          "every Assurance-type obligation that applies to that kind of event, and generates a checklist "
          "item for each one, with a due date calculated from the obligation's frequency and the SLA Master.")
table(doc, ["Step", "What happens", "Where"], [
    ("1", "An event occurs in the real world (a joiner, a leaver, a new asset).", "-"),
    ("2", "A user records the occurrence, naming the event and its subject.", "Raise Event"),
    ("3", "GRAC finds the Assurance obligations linked to that event type.", "Automatic"),
    ("4", "One checklist item is created per obligation, with a due date.", "Automatic"),
    ("5", "Owners complete each item and attach evidence.", "Event Checklists"),
], [700, 5800, 2860])

heading(doc, "6.2 Raise Event", 2)
heading(doc, "Purpose", 3)
para(doc, "Records that a tracked event has occurred and generates the resulting assurance checklist.")
heading(doc, "Fields", 3)
table(doc, FIELD_HEADERS, [
    ("Event Domain", "Yes", "The top level of the event taxonomy (e.g. People, Asset, Vendor). Filters the "
                            "Event list below."),
    ("Event", "Yes", "The specific event type (e.g. Employee Exit, Server Commissioned)."),
    ("Occurred On", "Yes", "When the event actually happened - this, not today's date, drives the due dates."),
    ("Subject", "Yes", "The specific record the event happened to. The picker is filtered to the subject type "
                       "the event expects."),
    ("Remarks", "No", "Any context the checklist owners should know."),
], FIELD_WIDTHS)
heading(doc, "Important business rules", 3)
bullet(doc, "The Subject picker only offers records of the entity type the event is defined against, so a "
            "'People' event cannot be raised against an asset.")
bullet(doc, "Occurred On may be backdated; due dates are calculated from it, so a backdated event can generate "
            "items that are already overdue.")
bullet(doc, "If no Assurance-type obligation is linked to the event type, the occurrence is still recorded but "
            "no checklist items are generated. This usually means the obligation is missing its Assurance "
            "detail (see 4.4).")
bullet(doc, "Some events are raised automatically by the platform - for example a new user account creates a "
            "People event without anyone opening this screen.")
heading(doc, "Approval behaviour", 3)
para(doc, "Raising an event does not go through maker-checker. The obligations being checked are already "
          "governed; recording that a governed rule was carried out is not itself a change to the rule.")
screenshot(doc, "Raise Event form showing the Event Domain and Event cascade, Occurred On date and the "
                "filtered Subject picker.")

heading(doc, "6.3 Event Checklists", 2)
heading(doc, "Purpose", 3)
para(doc, "Lists every event occurrence with the progress of its generated checklist, and lets owners complete "
          "the individual items.")
heading(doc, "Grid columns", 3)
table(doc, ["Column", "Meaning"], [
    ("Event Name", "The event type that occurred."),
    ("Subject", "The specific record the event happened to."),
    ("Occurred On", "When the event took place."),
    ("Next Due On", "The earliest outstanding due date across the checklist."),
    ("Completed Items", "Number of checklist items marked complete."),
    ("Pending Items", "Number still outstanding and not yet overdue."),
    ("Overdue Items", "Number past their due date - the number to watch."),
    ("Status", "Open, Completed or Cancelled."),
], [2300, 7060])
heading(doc, "Working through a checklist", 3)
for text in [
    "Open Assurance Runtime, then Event Checklists.",
    "Find the occurrence - sort by Overdue Items to deal with the most pressing first.",
    "Open the row to see the individual checklist items. Each shows the obligation name, verification method, "
    "assurance party and due date as they stood when the event was raised.",
    "Perform the verification, then mark the item Complete and attach the evidence.",
    "If an item was completed in error, Reopen it. The reopen is recorded in the audit trail.",
    "If the whole occurrence was raised in error, Cancel it. Cancelling does not delete the record.",
]:
    step(doc, text)
callout(doc, "Why the snapshots matter", "Each checklist item stores the obligation name, verification method, "
                                         "scope and assurance party as they were when the event was raised. "
                                         "If the obligation is edited later, historical checklists still show "
                                         "what the assurer was actually asked to do.")
heading(doc, "Audit behaviour", 3)
para(doc, "Completion, reopen and cancellation are each written to the audit trail with the actor and "
          "timestamp, even though the screen itself is outside maker-checker.")
screenshot(doc, "Event Checklists grid with an expanded occurrence showing individual checklist items and "
                "their Complete / Reopen actions.")


# ---------------------------------------------------------------------------
# 7. Data Upload
# ---------------------------------------------------------------------------

doc.add_page_break()
heading(doc, "7. Data Upload", 1)
callout(doc, "New in 2.0", "Chapter 7 is new.", fill=NEW_FILL)

heading(doc, "7.1 Choosing Between Bulk and Single-Form", 2)
table(doc, ["Aspect", "Bulk Upload", "Single-Form Upload"], [
    ("Covers", "Ten entity types in one workbook", "One entity type per file"),
    ("Best for", "Onboarding a complete new regulation from scratch",
     "Adding or replacing one layer of an existing release"),
    ("Permission", "Add on every gated area - effectively CM_ADMIN only", "Add on that one entity only"),
    ("Release scoping", "Release identified by the data in the sheet", "Release chosen before download; "
                                                                       "locked into the template"),
    ("Replace mode", "Not available", "Available for structure, statements and mappings"),
], [1500, 3930, 3930])
callout(doc, "Recommendation", "Use Single-Form Upload unless you are genuinely loading a whole regulation "
                               "for the first time. It is safer: the permission gate is narrower, the template "
                               "is bound to one release, and a mistake affects one layer instead of ten.")

heading(doc, "7.2 Single-Form Upload", 2)
heading(doc, "Available forms", 3)
table(doc, ["Form", "Release-scoped", "Replace allowed"], [
    ("Source Structure", "Yes", "Yes"),
    ("Source Statement", "Yes", "Yes"),
    ("Practices", "No", "No"),
    ("Obligation Master", "No", "No"),
    ("Obligation Evidence Types", "No", "No"),
    ("Practice - Source Statement Mapping", "Yes", "Yes"),
    ("Practice Obligation Mapping", "Yes", "Yes"),
], [4500, 2430, 2430])
para(doc, "You only see the forms you have Add permission for.")
heading(doc, "Procedure", 3)
for text in [
    "Open Data Upload, then Single-Form Upload.",
    "Choose the form you want to load. If it is release-scoped, choose the Release as well.",
    "Click Download Template. The workbook arrives pre-filled with the Release label and Release Id, plus "
    "column-by-column instructions.",
    "Fill the rows. Do not add, remove or rename columns, and do not touch the hidden context sheet.",
    "Click Validate and upload the file. The platform checks every row and reports problems without saving "
    "anything.",
    "Fix any reported issues in the workbook and validate again until it comes back clean.",
    "Click Commit. The whole file is applied as a single unit - if any row fails, nothing is saved.",
]:
    step(doc, text)
callout(doc, "Do not edit the hidden sheet", "Release-scoped templates carry a hidden context sheet holding the "
                                             "entity, the release and a signature. If the Release Id, the "
                                             "entity or the signature is altered, the commit is rejected. This "
                                             "stops a template downloaded for one release from being loaded "
                                             "into another by accident.", fill=WARN_FILL)
screenshot(doc, "Single-Form Upload screen showing the entity selector, Release selector, and the Download "
                "Template / Validate / Commit buttons.")

heading(doc, "7.3 Replace Mode", 2)
para(doc, "By default an upload adds to what is already there. Replace mode first clears the existing rows for "
          "the selected release, then loads the file - useful when a regulator reissues a whole chapter.")
bullet(doc, "Replace is only offered for release-scoped forms, and only to users who also hold Delete "
            "permission on that entity.")
bullet(doc, "Before committing, use Preview Replace to see exactly how many rows would be removed.")
bullet(doc, "You must type the release code to confirm. This is deliberate friction - replace is destructive.")
bullet(doc, "Practices and Obligation Master cannot be replaced, because too many other records point at them.")

heading(doc, "7.4 Bulk Upload", 2)
para(doc, "A single workbook with one sheet per entity, covering Authority, Artifact, Release, Source "
          "Structure, Source Statement, Practice, Obligation Master, Obligation Evidence Types, Practice - "
          "Source Statement Mapping and Practice Obligation Mapping.")
for text in [
    "Open Data Upload, then Bulk Upload.",
    "Click Download Template to get the empty multi-sheet workbook.",
    "Fill each sheet, working top down - parents before children. Cross-sheet references use the codes you "
    "entered, not database identifiers.",
    "Click Validate. The report lists every problem with its sheet, row and column.",
    "Download the error report if there are many issues - it is the same workbook annotated with what went "
    "wrong.",
    "Correct and re-validate until clean, then Commit.",
]:
    step(doc, text)
callout(doc, "All or nothing", "A bulk commit is atomic. If any row in any sheet fails, the entire upload is "
                               "rolled back and nothing is written. You will never end up with half a "
                               "regulation loaded.")

heading(doc, "7.5 Common Upload Errors", 2)
table(doc, ["Message", "Cause", "Fix"], [
    ("Unknown entity", "The entity key in the file does not match a known form.",
     "Re-download the template rather than reusing an old one."),
    ("You do not have permission to add '<form>'", "Your role lacks Add on that entity.",
     "Ask an administrator to grant Add on that menu."),
    ("Parent node reference not found", "A structure row names a parent that is not in the file or in the "
                                        "release.",
     "Add the parent row above the child, or correct the reference."),
    ("Statement reference already exists", "The release already has a statement with that reference.",
     "Use a unique reference, or switch to Replace mode if you intend to reload the chapter."),
    ("Context sheet signature invalid", "The hidden context sheet was edited, or the file was built from a "
                                        "different release's template.",
     "Download a fresh template for the correct release and re-enter the rows."),
    ("No file was uploaded", "The file was empty or not attached.", "Re-attach the workbook."),
], [2600, 3380, 3380])


# ---------------------------------------------------------------------------
# 8. Change Management
# ---------------------------------------------------------------------------

doc.add_page_break()
heading(doc, "8. Change Management", 1)

heading(doc, "8.1 Maker-Checker Concept", 2)
para(doc, "GRAC enforces segregation of duties through a maker-checker workflow. The 'maker' submits a change "
          "(Add, Edit, or Inactive). The 'checker' reviews and either approves, rejects, or sends back for "
          "revision. The main repository table is updated only after approval.")

heading(doc, "8.2 The Five Workflow Outcomes", 2)
table(doc, ["Workflow Configuration", "Outcome on Save"], [
    ("Approval Required = No",
     "Change is applied directly to the main table. No change request is created. A single audit event records "
     "the Add/Edit/Inactive."),
    ("Approval Required = Yes, Self Approval Allowed = No",
     "Change Request is created with status 'Pending Approval'. Main table is NOT updated. A different user "
     "with Approve permission must action the request."),
    ("Approval Required = Yes, Self Approval Allowed = Yes, maker lacks Approve permission",
     "Change Request is created with status 'Pending Approval' (same as the row above)."),
    ("Approval Required = Yes, Self Approval Allowed = Yes, maker has Approve permission",
     "Change Request is created with status 'Auto Approved'. Main table is updated immediately. The approval "
     "log records 'AUTO_APPROVE' against the maker."),
    ("Action = APPROVE on a Pending Change Request by a different user",
     "Change Request status moves to 'Approved'; main table is updated."),
], [4000, 5360])

heading(doc, "8.3 Approvals Menu", 2)
heading(doc, "Purpose", 3)
para(doc, "The Approvals queue lists every change request raised under a maker-checker enabled module. From "
          "here, an approver can View, Approve, Reject or Send Back any pending change request.")
heading(doc, "Columns", 3)
table(doc, ["Column", "Meaning"], [
    ("Change Request Number", "Auto-generated identifier (CR-000123)."),
    ("Module / Entity", "The module the request belongs to (Authority, Artifact, Release, etc.)."),
    ("Record Name / Reference", "Human-friendly identifier of the record being changed."),
    ("Action Type", "Add, Edit or Inactive."),
    ("Maker", "The user who raised the request."),
    ("Submitted On", "Date/time the maker submitted (IST)."),
    ("Checker", "Once actioned, the user who actioned the request."),
    ("Checked On", "Once actioned, the date/time (IST)."),
    ("Status", "Pending Approval / Approved / Auto Approved / Rejected / Sent Back."),
], [2300, 7060])
heading(doc, "Actions available from the 3-dot menu", 3)
table(doc, ["Action", "Effect", "Required Permission"], [
    ("View", "Opens the request in read-only mode showing old vs new values.", "View on Approvals"),
    ("Approve", "Applies the change to the main table; status becomes Approved.",
     "Approve on the target module"),
    ("Reject", "Requires checker comments; status becomes Rejected; main table unchanged.",
     "Reject on the target module"),
    ("Send Back", "Requires checker comments; status becomes Sent Back so the maker can revise and resubmit.",
     "Reject on the target module"),
], [1400, 5360, 2600])
callout(doc, "Self Approval", "If the workflow allows Self Approval, the maker is permitted to approve their "
                              "own change - provided they also hold the Approve permission. Otherwise the "
                              "message 'Self approval is not allowed for this module.' is shown.")

heading(doc, "8.4 Approval Workflow Menu", 2)
heading(doc, "Purpose", 3)
para(doc, "Configures the maker-checker policy per Module. Each Module can have exactly one active "
          "configuration. The configuration is keyed on the Module's canonical entity code (selected from a "
          "master list), not on a typed name - so spelling mismatches cannot cause the policy lookup to miss.")
heading(doc, "Fields", 3)
table(doc, FIELD_HEADERS, [
    ("Module", "Yes", "Pick from the entity master (Authority, Artifact, Release, Source Statements, "
                      "Practices, Obligation Master, User Management, etc.)."),
    ("Maker Roles", "No", "Comma-separated role codes who can submit a change."),
    ("Maker Users", "No", "Comma-separated login IDs who can submit a change."),
    ("Checker Roles", "No", "Comma-separated role codes who can approve / reject / send back."),
    ("Checker Users", "No", "Comma-separated login IDs who can approve / reject / send back."),
    ("Approval Required", "Yes", "Yes routes saves through the queue; No applies directly."),
    ("Self Approval Allowed", "Yes", "Yes lets the maker also approve their own change (provided they hold "
                                     "Approve permission)."),
    ("Minimum Approvers", "Yes", "Reserved for future N-eyes flow; currently 1."),
    ("Status", "Yes", "Active or Inactive."),
], FIELD_WIDTHS)
heading(doc, "Important business rules", 3)
bullet(doc, "Only one Active workflow row per Module. Trying to add a duplicate raises 'Approval workflow "
            "already exists for this module.'")
bullet(doc, "Module Name is sourced from the entity master and stored as a reference - typed-text mismatches "
            "are impossible.")
bullet(doc, "Self Approval is enforced server-side. The 'Self approval is not allowed for this module.' "
            "message means the workflow row has Self Approval Allowed = No.")
bullet(doc, "Event Checklists and event occurrences are registered as direct-write and are not affected by "
            "this configuration.")
screenshot(doc, "Approval Workflow dialog with the 'Module' dropdown populated from the entity master.")

heading(doc, "8.5 Bundled Approvals", 2)
callout(doc, "New in 2.0", "Applies to the Obligation Master save.", fill=NEW_FILL)
para(doc, "Saving an obligation can change several things at once: the master record, its type assignment, its "
          "typed detail, and its evidence links. Approving those separately would allow an obligation to end "
          "up half-approved - a master with no detail, or detail pointing at a type that was rejected.")
para(doc, "Instead, one save produces a bundle: several change requests tied together and applied in a fixed "
          "order. The checker sees them as one item and approves or rejects the whole bundle.")
bullet(doc, "A bundle is approved as a unit. There is no way to approve part of it.")
bullet(doc, "Rejecting or sending back a bundle returns every row in it to the maker.")
bullet(doc, "Each row in the bundle still carries its own before/after values, so the checker can review the "
            "detail line by line before deciding.")


# ---------------------------------------------------------------------------
# 9. Access Administration
# ---------------------------------------------------------------------------

doc.add_page_break()
heading(doc, "9. Access Administration", 1)
para(doc, "Access Administration controls who can use GRAC and what they can do. All four menus below support "
          "server-side pagination (10 / 25 / 50 / 100 per page), search, and the standard 3-dot action menu.")

heading(doc, "9.1 User Management", 2)
heading(doc, "Purpose", 3)
para(doc, "Captures the system's user accounts and the roles each user holds. The Add User form does not "
          "collect a password - the platform generates a hash of the configured default password and stamps "
          "the user as 'must change password on first login'.")
heading(doc, "Fields", 3)
table(doc, FIELD_HEADERS, [
    ("User Name", "Yes", "Display name."),
    ("Login ID", "Yes", "Plain text identifier used at sign-in."),
    ("Email", "Yes", "Email address; can also be used at sign-in."),
    ("Roles", "No", "One or more Roles from Role Management."),
    ("Remarks", "No", "Free-text notes."),
    ("Status", "Yes", "Active or Inactive (default Active on Add)."),
], FIELD_WIDTHS)
heading(doc, "Additional action", 3)
table(doc, ["Action", "Effect"], [
    ("Reset Password", "Re-stamps the user's password to the configured default and forces first-login change. "
                       "A confirmation dialog is shown before the reset. An audit event 'Admin Password Reset' "
                       "is written."),
], [2000, 7360])
heading(doc, "Important business rules", 3)
bullet(doc, "Login ID and Email are both unique (case-insensitive).")
bullet(doc, "A password is never accepted from the browser. The server alone decides what is hashed and stored.")
bullet(doc, "Reset Password requires Edit permission on User Management.")
bullet(doc, "Creating a user may automatically raise a People event and generate an onboarding assurance "
            "checklist - see Chapter 6.")

heading(doc, "9.2 Role Management", 2)
heading(doc, "Purpose", 3)
para(doc, "Defines the system's named roles. Roles are referenced from User Management (which users hold the "
          "role) and from Role Permission Management (what menus the role can see / act on).")
heading(doc, "Fields", 3)
table(doc, FIELD_HEADERS, [
    ("Role Name", "Yes", "Unique role code (e.g. CM_ADMIN, COMPLIANCE_READER)."),
    ("Description", "No", "Human-friendly explanation of what the role does."),
    ("Status", "Yes", "Active or Inactive."),
], FIELD_WIDTHS)
heading(doc, "Important business rules", 3)
bullet(doc, "Role Name must be unique.")
bullet(doc, "Inactivating a role keeps existing assignments but prevents the role from being added to new users.")

heading(doc, "9.3 Menu Management", 2)
heading(doc, "Purpose", 3)
para(doc, "Captures the application's navigation tree. Menus drive the left-rail navigation and are the unit "
          "at which Role Permissions are configured.")
heading(doc, "Fields", 3)
table(doc, FIELD_HEADERS, [
    ("Parent Menu", "No", "If blank, the menu is a top-level group; otherwise it is a child of the chosen parent."),
    ("Menu Name", "Yes", "Display label."),
    ("Menu Code", "Yes", "Unique identifier used internally (e.g. 'role-permissions')."),
    ("Route / URL", "No", "The page path the menu opens."),
    ("Display Order", "Yes", "Position inside the parent (lower = higher in the list)."),
    ("Icon", "No", "FontAwesome icon class without the 'fa-' prefix."),
    ("Status", "Yes", "Active or Inactive."),
], FIELD_WIDTHS)
heading(doc, "Important business rules", 3)
bullet(doc, "Menu Code must be unique.")
bullet(doc, "Inactivating a Menu hides it from every user's sidebar regardless of their Role Permissions.")

heading(doc, "9.4 Role Permission Management", 2)
heading(doc, "Purpose", 3)
para(doc, "Configures which actions each Role can perform against each Menu. The matrix has five permission "
          "flags: View, Add, Edit, Inactive (i.e. soft delete) and Approve.")
heading(doc, "Fields", 3)
table(doc, FIELD_HEADERS, [
    ("Role", "Yes", "Role being configured."),
    ("Menu", "Yes", "Menu being configured."),
    ("View", "Yes", "Yes/No - controls visibility of the menu and the grid."),
    ("Add", "Yes", "Yes/No - shows the Add button."),
    ("Edit", "Yes", "Yes/No - shows the Edit action in the 3-dot menu."),
    ("Inactive", "Yes", "Yes/No - shows the Inactive action; reused as the 'soft delete' permission."),
    ("Approve", "Yes", "Yes/No - shows Approve / Reject / Send Back in the Approvals queue, and the "
                       "Publish / Retire actions on assurance metadata."),
    ("Status", "Yes", "Active or Inactive."),
], FIELD_WIDTHS)
heading(doc, "Important business rules", 3)
bullet(doc, "(Role, Menu) is unique - re-saving the same pair updates the flags instead of failing.")
bullet(doc, "An admin role with full access overrides the per-menu matrix and sees everything.")
bullet(doc, "If a menu is invisible to a user, the most likely cause is a missing View permission on (their "
            "Role, this Menu).")
bullet(doc, "Obligation typed-detail screens inherit the Obligation Master permissions - you do not grant "
            "rights per obligation type.")
screenshot(doc, "Role Permission grid showing Role, Menu and the View/Add/Edit/Inactive/Approve toggles.")


# ---------------------------------------------------------------------------
# 10. Audit Traceability
# ---------------------------------------------------------------------------

doc.add_page_break()
heading(doc, "10. Audit Traceability", 1)
para(doc, "Every meaningful action - Add, Edit, Inactive, Approve, Reject, Send Back, Password Change, Admin "
          "Password Reset, checklist completion - writes one immutable audit row. The Audit Traceability menu "
          "lets you investigate exactly who did what, when, and what changed.")

heading(doc, "10.1 Hierarchical Grid", 2)
para(doc, "The grid is a tree. The parent row is the audit event header (entity, record, action, who, when). "
          "The expanded child rows show the field-level differences (Field, Old Value, New Value).")
table(doc, ["Column", "Meaning"], [
    ("Module / Entity", "Module the change belongs to (e.g. 'authorities', 'user-management')."),
    ("Record Name / Reference", "Human-friendly identifier of the record."),
    ("Action Type", "Add / Edit / Inactive / Status Change / Password Change / Admin Password Reset."),
    ("Changed By", "Login ID of the actor."),
    ("Changed On", "Date/time in IST (Asia/Kolkata)."),
    ("Field Changed", "(Detail row) The field that moved."),
    ("Old Value", "(Detail row) Value before the change."),
    ("New Value", "(Detail row) Value after the change."),
    ("Status", "Current row status (Active, Inactive, etc.)."),
], [2300, 7060])

heading(doc, "10.2 Filters and Paging", 2)
bullet(doc, "Search box matches across entity type, record reference and changed-by.")
bullet(doc, "Module / Entity dropdown limits the grid to one module at a time.")
bullet(doc, "Change Type dropdown limits the grid to one action type.")
bullet(doc, "Status filter is also available.")
bullet(doc, "Pagination at the bottom of the grid (10 / 25 / 50 / 100 rows per page) shows total record count "
            "and current page number.")

heading(doc, "10.3 IST Time Display", 2)
para(doc, "All change-date columns are stored in UTC and displayed in IST (Asia/Kolkata, UTC+05:30), so the "
          "displayed date/time always matches the local clock of GRAC India operations.")

heading(doc, "10.4 Immutability", 2)
para(doc, "Audit rows cannot be edited or deleted. Database triggers reject any UPDATE or DELETE against the "
          "audit tables. The same protection applies to assurance Version History.")
callout(doc, "Where to look for what", "Repository and obligation edits appear in Audit Traceability. "
                                       "Assurance metadata lifecycle transitions appear in Assurance "
                                       "Management, then Version History. Pending and historical change "
                                       "requests appear in Change Management, then Approvals.")


# ---------------------------------------------------------------------------
# 11. Common Workflows
# ---------------------------------------------------------------------------

doc.add_page_break()
heading(doc, "11. Common Workflows", 1)

_WORKFLOWS = [
    ("11.1 Create Authority, Artifact and Release", [
        "Sign in as an administrator. Open Repository Management, then Authority.",
        "Click Add. Enter Code, Name, Jurisdiction and Website. Set Status = Active. Save.",
        "Open the new Authority's 3-dot menu and drill through to Artifacts. The Artifact dialog opens "
        "pre-filled with the Authority.",
        "Enter Artifact Code, Name, Category, Industries, Jurisdictions. Save.",
        "From the new Artifact row, drill through to Releases. Enter Version, Effective Date, Release Notes. "
        "Save.",
        "If the module is maker-checker enabled, the Approvals queue will show the new requests as 'Pending "
        "Approval' - a checker must approve before they appear in the main grids.",
    ]),
    ("11.2 Load a Release's Structure and Statements by Upload", [
        "Open Data Upload, then Single-Form Upload.",
        "Choose Source Structure and the target Release. Download the template.",
        "Fill in the nodes - parents before children, using nodeReference to point at parents. Validate, fix, "
        "then Commit.",
        "Repeat with the Source Statement form for the same Release, referencing the structure nodes you just "
        "created.",
        "Open Repository Management, then Source Structure, and confirm the tree renders as expected.",
    ]),
    ("11.3 Create an Obligation and Map It", [
        "Open Obligation Management, then Obligation Master. Click Add.",
        "Enter the Obligation Name. Review the similar-obligation list that appears - if the obligation "
        "already exists, use it instead of creating a duplicate.",
        "Choose the Obligation Type. The typed detail panel changes to match.",
        "Fill the typed detail fields (see 4.4), then attach any evidence specifications.",
        "Save. The master, type, detail and evidence links are submitted together as one bundle.",
        "Once approved, open Practices - Obligation Mapping. Click Add, pick the Practice and Release, and "
        "select the obligation. Save.",
    ]),
    ("11.4 Set Up Assurance Metadata", [
        "Open Assurance Management, then Frequency Types. Add the frequencies your organisation uses. Submit, "
        "approve and publish each one.",
        "Repeat for Observation Severity, Gap Categories and Question Types - these are the vocabularies "
        "everything else refers to.",
        "Add a Scoring Model with its formula type, rating scale and pass threshold. Publish it.",
        "Add a Workflow Template with stages, SLA hours and an escalation rule. Publish it.",
        "Open SLA Master and define the SLA for each process and classification combination.",
        "Optionally bundle the above into a Starter Assurance Template so new assurances can be created in "
        "one step.",
    ]),
    ("11.5 Raise an Event and Clear Its Checklist", [
        "Confirm the relevant obligations are of type Assurance and have their verification method and "
        "frequency filled in - without this, no checklist is generated.",
        "Open Assurance Runtime, then Raise Event.",
        "Choose the Event Domain, then the Event. Set Occurred On to the real date of the event.",
        "Pick the Subject - the specific person, asset or vendor the event happened to. Add remarks. Save.",
        "Open Event Checklists and locate the new occurrence.",
        "Work through each checklist item: perform the verification, attach evidence, mark it Complete.",
        "Monitor the Overdue Items column across occurrences to see what needs attention.",
    ]),
    ("11.6 Submit and Approve a Repository Change", [
        "Maker performs Add / Edit / Inactive on a maker-checker enabled module.",
        "On save, the system displays 'Change submitted for approval' (or 'Change saved and auto-approved' if "
        "the workflow permits and the maker holds Approve permission).",
        "Checker opens Change Management, then Approvals.",
        "Checker filters by Module if needed, opens the 3-dot menu on the relevant row, and clicks View to "
        "inspect Old / New values.",
        "Checker clicks Approve, Reject, or Send Back. Comments are mandatory for Reject and Send Back.",
        "On Approve, the main repository table updates; the maker can refresh the source grid to see the "
        "change live.",
    ]),
    ("11.7 Publish a New Version of Assurance Metadata", [
        "Open the assurance master you need to change (for example Scoring Models).",
        "Locate the Published record. You cannot edit it directly - the platform will refuse with 'Approved, "
        "Published or Retired records cannot be edited directly. Create a new version instead.'",
        "Click Add and re-enter the record with the same Code and the next Version label. It is created in "
        "Draft.",
        "Make the changes and Save, then Submit. The record moves to Review.",
        "An approver opens the record and clicks Approve, then Publish.",
        "Retire the superseded version so only one version of that Code is Published at a time.",
        "Open Version History and confirm both transitions are recorded.",
    ]),
    ("11.8 Configure User Role Permissions", [
        "Open Access Administration, then Role Management. Create the Role if it does not exist.",
        "Open Access Administration, then User Management. Create / edit the User and assign the Role.",
        "Open Access Administration, then Role Permission Management.",
        "Click Add. Pick the Role and the Menu. Toggle View / Add / Edit / Inactive / Approve as appropriate. "
        "Save.",
        "Sign the user out and back in to refresh their permission cache. The user now sees the configured "
        "menus and actions.",
    ]),
]

for title, steps in _WORKFLOWS:
    heading(doc, title, 2)
    for text in steps:
        step(doc, text)


# ---------------------------------------------------------------------------
# 12. Troubleshooting
# ---------------------------------------------------------------------------

doc.add_page_break()
heading(doc, "12. Troubleshooting", 1)
table(doc, ["Symptom", "Likely Cause", "How to Fix"], [
    ("Menu not visible in the sidebar",
     "The user's Role has no View permission for that Menu (or the Menu itself is Inactive).",
     "Open Role Permission Management, find (Role, Menu), set View = Yes. Confirm the Menu row in Menu "
     "Management is Active."),
    ("Login fails with 'Invalid Login ID / Email or Password'",
     "Wrong credentials or an inactive user.",
     "Verify the user is Active in User Management. If the password was forgotten, an admin can run Reset "
     "Password from the 3-dot menu."),
    ("First-login redirect loop on Change Password",
     "The password change failed - most often a typo on Current Password.",
     "Re-enter the current/default password exactly. Choose a new password of at least 8 characters."),
    ("Permission denied when clicking Add or Edit",
     "Role lacks the corresponding flag on this Menu.",
     "Update (Role, Menu) in Role Permission Management. Sign out and in to refresh."),
    ("Record not visible after save",
     "The module is maker-checker enabled and the row is awaiting approval.",
     "Check Change Management, then Approvals; the row will be 'Pending Approval'."),
    ("Record stays 'Pending Approval' for a long time",
     "No user with Approve permission has actioned it.",
     "Identify a user with Approve permission for the module, or configure the Approval Workflow with "
     "appropriate Checker Roles."),
    ("'Self approval is not allowed for this module.'",
     "The Approval Workflow for the module has Self Approval Allowed = No.",
     "Ask a different user with Approve permission to approve, or update the workflow setting."),
    ("Typed detail panel does not appear on the Obligation form",
     "The obligation has no Obligation Type assigned, or the type is Evidence (which has no detail table).",
     "Assign a type first. For Evidence, use the evidence specification panel instead."),
    ("Raising an event produces no checklist items",
     "No Assurance-type obligation is linked to that event type, or the linked obligations have no Assurance "
     "detail.",
     "Open the relevant obligations, confirm the type is Assurance and that Verification Method and Assurance "
     "Frequency are filled in."),
    ("'Approved, Published or Retired records cannot be edited directly'",
     "You are trying to edit assurance metadata that is past Draft.",
     "Create a new version instead - see workflow 11.7."),
    ("Upload rejected with a context signature error",
     "The hidden context sheet was edited, or the file came from a different release's template.",
     "Download a fresh template for the correct release and re-enter the rows."),
    ("Bulk Upload menu is not available",
     "Bulk Upload requires Add permission on every gated repository area.",
     "Use Single-Form Upload, or ask an administrator to run the bulk load."),
    ("Replace option is greyed out on Single-Form Upload",
     "Replace needs Delete permission on that entity, and is not offered for Practices or Obligation Master.",
     "Request Delete permission, or load the rows additively."),
    ("Checklist item due date looks wrong",
     "Due dates are calculated from Occurred On, not from today, and are shaped by the SLA Master.",
     "Check the Occurred On value on the occurrence and the SLA row for that process and classification."),
    ("Filter dropdown is empty (e.g. Release filter has no items)",
     "The dependent context has no Active records, or the user has no View permission on that lookup.",
     "Verify the parent records exist and are Active; verify View on the relevant Menu."),
    ("Audit data not showing for a record",
     "Wrong filter combination, or the record predates audit being switched on.",
     "Clear filters in Audit Traceability and search by record reference."),
], [2600, 3380, 3380])


# ---------------------------------------------------------------------------
# 13. Appendix
# ---------------------------------------------------------------------------

doc.add_page_break()
heading(doc, "13. Appendix", 1)

heading(doc, "13.1 Status Definitions", 2)
table(doc, ["Status", "Meaning"], [
    ("Active", "The record is live and participates in lookups."),
    ("Inactive", "The record is hidden from new lookups but kept for history."),
    ("Draft", "(Releases, assurance metadata) Being prepared and not yet live."),
    ("Retired", "(Releases / Source Structure / Source Statements) Superseded by a newer version."),
    ("Review", "(Assurance metadata) Submitted and awaiting a decision."),
    ("Approved", "(Assurance metadata) Accepted but not yet published."),
    ("Published", "(Assurance metadata) Live and in use."),
    ("Open", "(Event occurrence) Checklist items remain outstanding."),
    ("Completed", "(Event occurrence) Every checklist item is complete."),
    ("Cancelled", "(Event occurrence) Raised in error and withdrawn; the record is retained."),
], [2000, 7360])

heading(doc, "13.2 Approval Statuses", 2)
table(doc, ["Status", "Meaning"], [
    ("Pending Approval", "The change request is in the queue waiting for a checker."),
    ("Approved", "A checker (different from the maker) approved the change."),
    ("Auto Approved", "Self Approval was enabled and the maker also held Approve permission; the change was "
                      "applied automatically."),
    ("Rejected", "A checker rejected the change. Mandatory comments captured."),
    ("Sent Back", "A checker returned the change to the maker for revision. Mandatory comments captured."),
], [2000, 7360])

heading(doc, "13.3 Permission Definitions", 2)
table(doc, ["Permission", "Effect on the UI / Server"], [
    ("View", "The menu appears in the sidebar; the grid loads data; the View action is available."),
    ("Add", "The Add button on the page heading appears; new rows can be created; upload forms become available."),
    ("Edit", "The Edit action appears in the 3-dot menu. Also required for Reset Password on User Management "
             "and for Submit on assurance metadata."),
    ("Inactive", "The Inactive action appears in the 3-dot menu; rows can be soft-deleted. Also required for "
                 "Replace mode on Single-Form Upload."),
    ("Approve", "Approve / Reject / Send Back appear on Approvals; Publish and Retire appear on assurance "
                "metadata. Also enables Auto Self Approval when Self Approval is allowed."),
    ("Reject", "Permits rejection and send-back."),
], [2000, 7360])

heading(doc, "13.4 Glossary", 2)
table(doc, ["Term", "Definition"], [
    ("Authority", "The regulator, supervisor, standards body or internal owner that issues a regulatory artifact."),
    ("Artifact", "A specific regulatory instrument (circular, standard, framework, guideline)."),
    ("Release", "A published version of an Artifact. The unit of version control."),
    ("Source Classification", "A label scheme used inside a Release to categorise statements."),
    ("Source Structure", "The native hierarchy (chapters, sections) of a Release."),
    ("Source Statement", "An assessable regulatory clause under a Source Structure node."),
    ("Practice", "An atomic compliance activity / control maintained by the organisation."),
    ("Obligation", "A single thing a regulation requires: a condition, an activity, a check, a response, a "
                   "prohibition, a proof, or a retention period."),
    ("Obligation Type", "One of the seven atomic classifications: State, Execution, Assurance, Event Response, "
                        "Constraint, Evidence, Retention."),
    ("Typed Detail", "The structured fields specific to an obligation's type."),
    ("Evidence Specification", "A reusable description of a proof artefact, attachable to many obligations."),
    ("Assurance Metadata", "The reusable configuration - categories, scoring, severity, workflow, sampling, "
                           "frequency, reports - that assurance activities are built from."),
    ("Lifecycle Status", "The Draft to Published progression that governs assurance metadata."),
    ("Event Type", "A category of real-world occurrence that assurance can be triggered by."),
    ("Occurrence", "A single recorded instance of an event happening to a specific subject."),
    ("Checklist Item", "One assurance obligation to be verified for one occurrence, with its own due date."),
    ("SLA Master", "Process and classification service levels driving warnings and escalation."),
    ("Change Request", "A maker-submitted Add / Edit / Inactive awaiting checker action."),
    ("Bundle", "A group of change requests from one composite save, approved or rejected together."),
    ("Approval Workflow", "Per-module configuration deciding whether saves go through maker-checker and "
                          "whether self approval is allowed."),
    ("Audit Trace", "Immutable record of every change with old / new values, actor and timestamp."),
    ("Maker", "User who submits a change request."),
    ("Checker", "User who approves, rejects or sends back a change request."),
    ("Self Approval", "Workflow setting that lets the maker also approve their own change, provided they hold "
                      "Approve permission."),
    ("IST", "Indian Standard Time (UTC+05:30). Audit timestamps are displayed in IST."),
], [2400, 6960])

para(doc, "End of manual", bold=True, color=MUTED, size=10,
     align=WD_ALIGN_PARAGRAPH.CENTER, before=18)

doc.save(OUT)
print(f"Written: {OUT}")
