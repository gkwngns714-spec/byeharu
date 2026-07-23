# -*- coding: utf-8 -*-
"""Render docs/DEV_LOG.md -> docs/Byeharu_Project_History.pdf (ReportLab Platypus).

Usage (from the repo root, Windows):
    pip install reportlab fonttools
    python docs/tools/render_devlog_pdf.py docs/DEV_LOG.md docs/Byeharu_Project_History.pdf <commit-sha>

Docs-only tooling. Reads nothing but the markdown file; writes nothing but the PDF.
Embeds Malgun Gothic / Consolas / Segoe UI Symbol from C:\\Windows\\Fonts (Korean +
symbol coverage). Characters covered by none of them are substituted via SUBST and
the substitution counts are printed at the end of a run.
"""
import re, sys, os, datetime
from fontTools.ttLib import TTFont as FTFont
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph,
                                XPreformatted, Spacer, Table, TableStyle, PageBreak,
                                KeepTogether)
from reportlab.platypus.flowables import HRFlowable
from reportlab.platypus.tableofcontents import TableOfContents

SRC = sys.argv[1]
OUT = sys.argv[2]
SHA = sys.argv[3]

F = 'C:/Windows/Fonts/'
pdfmetrics.registerFont(TTFont('Body', F + 'malgun.ttf'))
pdfmetrics.registerFont(TTFont('BodyB', F + 'malgunbd.ttf'))
pdfmetrics.registerFont(TTFont('Mono', F + 'consola.ttf'))
pdfmetrics.registerFont(TTFont('MonoB', F + 'consolab.ttf'))
pdfmetrics.registerFont(TTFont('Sym', F + 'seguisym.ttf'))
pdfmetrics.registerFontFamily('Body', normal='Body', bold='BodyB', italic='Body', boldItalic='BodyB')
pdfmetrics.registerFontFamily('Mono', normal='Mono', bold='MonoB', italic='Mono', boldItalic='MonoB')


def cov(p):
    return set(FTFont(F + p, fontNumber=0).getBestCmap().keys())


COV = {'Body': cov('malgun.ttf'), 'Mono': cov('consola.ttf'), 'Sym': cov('seguisym.ttf')}

# Characters covered by NO embedded font -> deliberate substitution (reported).
SUBST = {
    '\u2705': '\u2713',      # white heavy check mark -> check mark
    '\u23f3': '[wait]',      # hourglass
    '\U0001f4b0': '[$]',     # money bag
    '\U0001f6f0': '[sat]',   # satellite
    '\ufe0f': '',            # variation selector-16 (zero width)
    '\ufe0e': '',
}
SUBST_HITS = {}


def presub(t):
    for k, v in SUBST.items():
        if k in t:
            SUBST_HITS[k] = SUBST_HITS.get(k, 0) + t.count(k)
            t = t.replace(k, v)
    return t


def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def fb(text, base):
    """Escape + wrap characters missing from `base` in a fallback font."""
    text = presub(text)
    out = []
    buf = []
    cur = None
    bc = COV[base]
    for ch in text:
        if ch in '\n\t' or ord(ch) in bc:
            want = None
        elif ord(ch) in COV['Sym']:
            want = 'Sym'
        elif base != 'Body' and ord(ch) in COV['Body']:
            want = 'Body'
        else:
            want = 'MISS'
        if want != cur:
            if buf:
                out.append((cur, ''.join(buf)))
            buf = []
            cur = want
        buf.append(ch)
    if buf:
        out.append((cur, ''.join(buf)))
    parts = []
    for f, t in out:
        if f is None:
            parts.append(esc(t))
        elif f == 'MISS':
            MISSING.update(t)
            parts.append(esc(t))
        else:
            parts.append('<font name="%s">%s</font>' % (f, esc(t)))
    return ''.join(parts)


MISSING = set()

INLINE = re.compile(
    r'(?P<code>`+)(?P<codetxt>.+?)(?P=code)'
    r'|\*\*(?P<b>.+?)\*\*'
    r'|__(?P<b2>.+?)__'
    r'|(?<![\*\w])\*(?!\*)(?P<i>[^\*\n]+?)\*(?!\*)'
    r'|\[(?P<lt>[^\]\n]*)\]\((?P<lu>[^)\s]+)[^)]*\)'
    r'|~~(?P<s>.+?)~~', re.S)


def inline(text, base='Body', csize=8.0):
    res = []
    pos = 0
    for m in INLINE.finditer(text):
        res.append(fb(text[pos:m.start()], base))
        if m.group('codetxt') is not None:
            res.append('<font name="Mono" size="%.2f" backColor="#f0f0f2">%s</font>'
                       % (csize, fb(m.group('codetxt'), 'Mono')))
        elif m.group('b') is not None:
            res.append('<b>%s</b>' % inline(m.group('b'), base, csize))
        elif m.group('b2') is not None:
            res.append('<b>%s</b>' % inline(m.group('b2'), base, csize))
        elif m.group('i') is not None:
            res.append('<i>%s</i>' % inline(m.group('i'), base, csize))
        elif m.group('lt') is not None:
            res.append('<font color="#1a4f8a">%s</font>' % inline(m.group('lt'), base, csize))
        elif m.group('s') is not None:
            res.append('<strike>%s</strike>' % inline(m.group('s'), base, csize))
        pos = m.end()
    res.append(fb(text[pos:], base))
    return ''.join(res)


def P(text, style, **kw):
    return Paragraph(inline(text, 'Body', round(style.fontSize * 0.92, 2)), style, **kw)


def measure(text, size):
    """Width estimate honouring inline-code runs rendered in Mono at 0.92x."""
    w = 0.0
    for i, seg in enumerate(re.split(r'`+', text)):
        seg = re.sub(r'[\*_~\[\]]', '', seg)
        if i % 2:
            w += pdfmetrics.stringWidth(seg, 'Mono', size * 0.92)
        else:
            w += pdfmetrics.stringWidth(seg, 'Body', size)
    return w


# ---------------- styles ----------------
PW, PH = A4
LM, RM, TM, BM = 16 * mm, 14 * mm, 17 * mm, 15 * mm
AVAIL = PW - LM - RM

S = {}
S['body'] = ParagraphStyle('body', fontName='Body', fontSize=8.6, leading=12.2,
                           spaceBefore=2, spaceAfter=4, alignment=TA_LEFT,
                           textColor=colors.HexColor('#15181d'), wordWrap='CJK',
                           splitLongWords=1, allowWidows=0, allowOrphans=0,
                           bulletFontName='Body', bulletFontSize=8.0)
S['h1'] = ParagraphStyle('h1', parent=S['body'], fontName='BodyB', fontSize=19, leading=24,
                         spaceBefore=14, spaceAfter=8, textColor=colors.HexColor('#0d1b2a'))
S['h2'] = ParagraphStyle('h2', parent=S['body'], fontName='BodyB', fontSize=13.5, leading=17.5,
                         spaceBefore=15, spaceAfter=6, textColor=colors.HexColor('#123a63'))
S['h3'] = ParagraphStyle('h3', parent=S['body'], fontName='BodyB', fontSize=10.8, leading=14,
                         spaceBefore=10, spaceAfter=4, textColor=colors.HexColor('#1d4f7c'))
S['h4'] = ParagraphStyle('h4', parent=S['body'], fontName='BodyB', fontSize=9.4, leading=12.5,
                         spaceBefore=8, spaceAfter=3, textColor=colors.HexColor('#3a3f47'))
S['quote'] = ParagraphStyle('quote', parent=S['body'], leftIndent=9, rightIndent=4,
                            borderPadding=(3, 4, 3, 6), backColor=colors.HexColor('#f4f6f9'),
                            textColor=colors.HexColor('#333a44'), spaceBefore=3, spaceAfter=3)
S['code'] = ParagraphStyle('code', fontName='Mono', fontSize=7.4, leading=9.2,
                           backColor=colors.HexColor('#f5f5f7'), borderPadding=(4, 5, 4, 5),
                           borderColor=colors.HexColor('#e0e0e4'), borderWidth=0.4,
                           textColor=colors.HexColor('#1b1f24'), spaceBefore=4, spaceAfter=6)
S['cell'] = ParagraphStyle('cell', parent=S['body'], fontSize=7.4, leading=9.6,
                           spaceBefore=0, spaceAfter=0)
S['cellh'] = ParagraphStyle('cellh', parent=S['cell'], fontName='BodyB',
                            textColor=colors.HexColor('#10233a'))
S['tocH'] = ParagraphStyle('tocH', parent=S['body'], fontSize=7.8, leading=10.6,
                           spaceBefore=0, spaceAfter=0.5, leftIndent=0, firstLineIndent=0)
S['title'] = ParagraphStyle('title', parent=S['body'], fontName='BodyB', fontSize=27, leading=33,
                            spaceAfter=6, textColor=colors.HexColor('#0d1b2a'))
S['sub'] = ParagraphStyle('sub', parent=S['body'], fontSize=11.5, leading=16,
                          textColor=colors.HexColor('#4a525c'))
for i in range(6):
    S['ul%d' % i] = ParagraphStyle('ul%d' % i, parent=S['body'], leftIndent=10 + 12 * i,
                                   bulletIndent=2 + 12 * i, spaceBefore=1, spaceAfter=1)

CODE_W = AVAIL - 12


def wrap_code(line):
    """Hard-wrap a code line to the frame width by measured width (never clip)."""
    fs = S['code'].fontSize
    out = []
    cur = ''
    w = 0.0
    ind = len(line) - len(line.lstrip(' '))
    cont = ' ' * min(ind + 2, 20)
    contw = pdfmetrics.stringWidth(cont, 'Mono', fs)
    first = True
    for ch in line:
        cw = pdfmetrics.stringWidth(ch, 'Mono', fs)
        if not COV['Mono'] or ord(ch) not in COV['Mono']:
            cw = pdfmetrics.stringWidth(ch, 'Body', fs)
        if w + cw > CODE_W and cur:
            out.append(cur)
            cur = cont
            w = contw
            first = False
        cur += ch
        w += cw
    out.append(cur)
    return out if out else ['']


# ---------------- parse ----------------
src = open(SRC, encoding='utf-8').read().replace('\r\n', '\n').replace('\t', '    ')
lines = src.split('\n')

story = []
ENTRIES = []
seq = [0]


def h(text, style, level=None, key=None):
    p = P(text, style)
    if level is not None:
        p._toc = (level, re.sub(r'[`*]', '', text), key)
    return p


def flush_para(buf):
    if buf:
        t = ' '.join(x.strip() for x in buf).strip()
        if t:
            story.append(P(t, S['body']))
        buf.clear()


def is_table_sep(l):
    return bool(re.match(r'^\s*\|?[\s:\-|]+\|[\s:\-|]*$', l)) and '-' in l and '|' in l


def split_row(l):
    l = l.strip()
    if l.startswith('|'):
        l = l[1:]
    if l.endswith('|'):
        l = l[:-1]
    # split on | not preceded by backslash and not inside inline code
    cells, cur, tick = [], '', False
    i = 0
    while i < len(l):
        c = l[i]
        if c == '`':
            tick = not tick
            cur += c
        elif c == '\\' and i + 1 < len(l) and l[i + 1] == '|':
            cur += '|'
            i += 1
        elif c == '|' and not tick:
            cells.append(cur)
            cur = ''
        else:
            cur += c
        i += 1
    cells.append(cur)
    return [c.strip() for c in cells]


DEGRADED = []


def emit_table(rows, ln):
    ncol = max(len(r) for r in rows)
    rows = [r + [''] * (ncol - len(r)) for r in rows]
    if ncol > 9:
        DEGRADED.append((ln, ncol, 'too many columns -> preformatted'))
        emit_code(['| ' + ' | '.join(r) + ' |' for r in rows])
        return
    # width by longest cell, min 8% max 45%
    raw = []
    for c in range(ncol):
        m = max(measure(rows[r][c][:140], 7.4) for r in range(len(rows)))
        raw.append(max(m + 8, 24))
    tot = sum(raw)
    if tot > AVAIL:
        raw = [w * AVAIL / tot for w in raw]
    data = [[P(c, S['cellh'] if i == 0 else S['cell']) for c in r]
            for i, r in enumerate(rows)]
    t = Table(data, colWidths=raw, repeatRows=1, hAlign='LEFT')
    t.setStyle(TableStyle([
        ('GRID', (0, 0), (-1, -1), 0.4, colors.HexColor('#c9ced6')),
        ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor('#e8edf4')),
        ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, colors.HexColor('#fafbfc')]),
        ('VALIGN', (0, 0), (-1, -1), 'TOP'),
        ('LEFTPADDING', (0, 0), (-1, -1), 3), ('RIGHTPADDING', (0, 0), (-1, -1), 3),
        ('TOPPADDING', (0, 0), (-1, -1), 2.5), ('BOTTOMPADDING', (0, 0), (-1, -1), 2.5),
    ]))
    story.append(Spacer(1, 3))
    story.append(t)
    story.append(Spacer(1, 5))


def emit_code(codelines):
    wrapped = []
    for l in codelines:
        wrapped.extend(wrap_code(l.rstrip()))
    txt = '\n'.join(fb(l, 'Mono') for l in wrapped)
    story.append(XPreformatted(txt, S['code']))


i = 0
para = []
n_tables = n_code = 0
while i < len(lines):
    l = lines[i]
    st = l.strip()
    # fenced code
    m = re.match(r'^\s*(```+|~~~+)(.*)$', l)
    if m:
        fence = m.group(1)[:3]
        j = i + 1
        buf = []
        while j < len(lines) and not lines[j].strip().startswith(fence):
            buf.append(lines[j])
            j += 1
        flush_para(para)
        emit_code(buf)
        n_code += 1
        i = j + 1
        continue
    if not st:
        flush_para(para)
        i += 1
        continue
    if re.match(r'^\s*(\*\s*\*\s*\*|-\s*-\s*-|_\s*_\s*_)[\s\-\*_]*$', l):
        flush_para(para)
        story.append(HRFlowable(width='100%', thickness=0.6, color=colors.HexColor('#d3d8de'),
                                spaceBefore=5, spaceAfter=5))
        i += 1
        continue
    hm = re.match(r'^(#{1,6})\s+(.*)$', st)
    if hm:
        flush_para(para)
        lvl = len(hm.group(1))
        txt = hm.group(2).rstrip('#').strip()
        if lvl == 1:
            story.append(h(txt, S['h1'], 0, 'h%d' % i))
        elif lvl == 2:
            seq[0] += 1
            key = 'e%d' % seq[0]
            ENTRIES.append(txt)
            story.append(HRFlowable(width='100%', thickness=1.1,
                                    color=colors.HexColor('#123a63'), spaceBefore=13,
                                    spaceAfter=1))
            story.append(h(txt, S['h2'], 1, key))
        elif lvl == 3:
            story.append(h(txt, S['h3'], 2, 'h%d' % i))
        else:
            story.append(h(txt, S['h4']))
        i += 1
        continue
    # table
    if st.startswith('|') and i + 1 < len(lines) and is_table_sep(lines[i + 1]):
        flush_para(para)
        rows = [split_row(l)]
        j = i + 2
        while j < len(lines) and lines[j].strip().startswith('|'):
            rows.append(split_row(lines[j]))
            j += 1
        emit_table(rows, i + 1)
        n_tables += 1
        i = j
        continue
    # blockquote
    if st.startswith('>'):
        flush_para(para)
        buf = []
        j = i
        while j < len(lines) and (lines[j].strip().startswith('>') or
                                  (lines[j].strip() and buf and not re.match(r'^\s*[#|`]', lines[j]) and not lines[j].strip().startswith('-'))):
            if not lines[j].strip().startswith('>'):
                break
            buf.append(re.sub(r'^\s*>\s?', '', lines[j]))
            j += 1
        chunk = []
        for b in buf:
            if not b.strip():
                if chunk:
                    story.append(P(' '.join(chunk), S['quote']))
                    chunk = []
            else:
                chunk.append(b.strip())
        if chunk:
            story.append(P(' '.join(chunk), S['quote']))
        i = j
        continue
    # list item
    lm = re.match(r'^(\s*)([-*+]|\d{1,3}[.)])\s+(.*)$', l)
    if lm:
        flush_para(para)
        depth = min(len(lm.group(1)) // 2, 4)
        marker = lm.group(2)
        bullet = ('\u2022', '\u25e6', '\u25aa', '\u2023', '-')[depth] if marker in '-*+' else marker
        txt = lm.group(3)
        j = i + 1
        while j < len(lines):
            nxt = lines[j]
            if not nxt.strip():
                break
            if re.match(r'^(\s*)([-*+]|\d{1,3}[.)])\s+', nxt) or re.match(r'^\s*(#|\||```|>)', nxt):
                break
            txt += ' ' + nxt.strip()
            j += 1
        story.append(P(txt, S['ul%d' % depth], bulletText=fb(bullet, 'Body')))
        i = j
        continue
    para.append(l)
    i += 1
flush_para(para)

# ---------------- doc ----------------
GEN = datetime.date.today().isoformat()
TITLE = 'Byeharu \u2014 Project History (Dev Log)'


class Doc(BaseDocTemplate):
    def afterFlowable(self, flowable):
        toc = getattr(flowable, '_toc', None)
        if toc:
            lvl, txt, key = toc
            if key:
                self.canv.bookmarkPage(key)
                self.canv.addOutlineEntry(txt[:110], key.encode(), max(lvl, 0), 0)
            if lvl == 1:
                self.notify('TOCEntry', (0, txt, self.page, key))


def deco(canvas, doc):
    canvas.saveState()
    canvas.setFont('Body', 7)
    canvas.setFillColor(colors.HexColor('#8b939d'))
    canvas.drawString(LM, PH - TM + 6, TITLE + '   \u00b7   docs/DEV_LOG.md @ ' + SHA[:7])
    canvas.setStrokeColor(colors.HexColor('#dfe3e8'))
    canvas.setLineWidth(0.4)
    canvas.line(LM, PH - TM + 3, PW - RM, PH - TM + 3)
    canvas.line(LM, BM - 5, PW - RM, BM - 5)
    canvas.drawString(LM, BM - 13, 'Generated %s' % GEN)
    canvas.drawRightString(PW - RM, BM - 13, str(canvas.getPageNumber()))
    canvas.restoreState()


def blank(canvas, doc):
    pass


doc = Doc(OUT, pagesize=A4, leftMargin=LM, rightMargin=RM, topMargin=TM, bottomMargin=BM,
          title='Byeharu Project History (DEV_LOG)', author='Byeharu', subject='docs/DEV_LOG.md @ ' + SHA)
frame = Frame(LM, BM, AVAIL, PH - TM - BM, id='n', leftPadding=0, rightPadding=0,
              topPadding=0, bottomPadding=0)
doc.addPageTemplates([
    PageTemplate(id='title', frames=[frame], onPage=blank),
    PageTemplate(id='main', frames=[frame], onPage=deco),
])

toc = TableOfContents()
toc.levelStyles = [S['tocH']]
toc.dotsMinLevel = 0

front = [
    Spacer(1, 46 * mm),
    Paragraph('Byeharu', S['title']),
    Paragraph('Project History \u2014 Development Log', S['sub']),
    Spacer(1, 10 * mm),
    HRFlowable(width='62%', thickness=1.2, color=colors.HexColor('#123a63'), hAlign='LEFT'),
    Spacer(1, 8 * mm),
]
meta = [['Source', 'docs/DEV_LOG.md'],
        ['Repository commit', SHA],
        ['Source size', '{:,} lines / {:,} bytes'.format(len(lines), len(src.encode('utf-8')))],
        ['Entries', '{} dated entries (newest first)'.format(len(ENTRIES))],
        ['Generated', GEN],
        ['Renderer', 'ReportLab Platypus (Malgun Gothic / Consolas / Segoe UI Symbol embedded)']]
mt = Table([[Paragraph('<b>%s</b>' % k, S['body']), P(v, S['body'])] for k, v in meta],
           colWidths=[42 * mm, AVAIL - 42 * mm], hAlign='LEFT')
mt.setStyle(TableStyle([('VALIGN', (0, 0), (-1, -1), 'TOP'),
                        ('BOTTOMPADDING', (0, 0), (-1, -1), 5),
                        ('LEFTPADDING', (0, 0), (0, -1), 0),
                        ('LINEBELOW', (0, 0), (-1, -2), 0.3, colors.HexColor('#e4e8ee'))]))
front.append(mt)
front.append(Spacer(1, 8 * mm))
front.append(Paragraph('This document is a complete, unabridged rendering of the development log '
                       'in its natural file order (newest entry first, oldest entry last).', S['body']))

full = front + [PageBreak(), Paragraph('Contents', S['h1']), toc, PageBreak()] + story
# switch template after title page
from reportlab.platypus.doctemplate import NextPageTemplate
full = [NextPageTemplate('main')] + full

doc.multiBuild(full)
print('ENTRIES', len(ENTRIES))
print('TABLES', n_tables, 'CODEBLOCKS', n_code)
print('DEGRADED', DEGRADED)
print('SUBST_HITS', SUBST_HITS)
print('MISSING_GLYPHS', sorted(MISSING))
