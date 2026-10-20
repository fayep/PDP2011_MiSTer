#!/usr/bin/env python3
"""mkpanel.py -- the PDP-11/70 front panel artwork for the on-screen panel view
(rtl/panel_view.sv): 640 x 480, 16 colours.

    uv run --with pillow tools/panel/mkpanel.py FONTDIR [--hex rtl/panel_art.hex]
        [--png out.png] [--state SEED] [--state-out state.txt] [--check frame.ppm]

FONTDIR holds the DejaVu fonts (DejaVu 2.37 ttf folder; free licence,
https://github.com/dejavu-fonts/dejavu-fonts). They are not in this repository:
the generated ROM image, rtl/panel_art.hex, is.

The picture is drawn twice: once in colours (the panel as it looks with every
lamp off), once as an object map that names, for each pixel, the live object
it belongs to: a lamp (its core or its glow ring), the light end of a paddle
in its up or its down position, or a knob pointer. The core keeps both as
runs of (colour, object) and only decides per object whether it is lit: a lit
object's pixels take its lit colour. So the core shows exactly what render()
here shows for the same state, and --check compares a simulated frame with it.

ROM word, 20 bits: colour[19:16] kind[15:14] n[13:7] length-1[6:0]; the runs
go in raster order, at most 128 pixels, never across a line. Objects:
  kind 1 lamp core (lit colour 12), kind 2 lamp glow ring (lit colour 13), n =
     0-21 ADDRESS bit n, 22-37 DATA bit n-22, 38-49 status lamp n-38 (left to
     right: PAR ERR, ADRS ERR, RUN, PAUSE, MASTER, USER, SUPER, KERNEL, DATA,
     16, 18, 22), 50/51 PARITY HIGH/LOW, 52-59 ADDRESS knob position n-52,
     60-63 DATA knob position n-60
  kind 3, n < 64: paddle light end (lit colour 14): 0-21 switch n up, 22-28
     control switch n-22 up (LOAD ADRS ... START), 32-53 switch n-32 down,
     54-60 control switch n-54 down
  kind 3, n >= 64: knob pointer (lit colour 4): 64-71 ADDRESS knob position
     n-64, 72-75 DATA knob position n-72
"""
import sys, math, random, argparse
from PIL import Image, ImageDraw, ImageFont

W, H = 640, 480
# palette: index -> RGB (rtl/panel_view.sv has the same table)
PAL = [
    (0xc8, 0xc1, 0xae),   # 0 beige surround
    (0x9e, 0x97, 0x86),   # 1 beige shadow / outline
    (0x1a, 0x18, 0x1c),   # 2 panel black
    (0x0c, 0x0b, 0x0d),   # 3 lamp well / window black
    (0xee, 0xec, 0xe6),   # 4 label white
    (0x9a, 0x98, 0xa0),   # 5 grey (text edge, knob)
    (0x4c, 0x4a, 0x50),   # 6 dark grey
    (0xc8, 0x22, 0x3a),   # 7 red
    (0x88, 0x14, 0x26),   # 8 red dark
    (0x7c, 0x1e, 0x7e),   # 9 purple
    (0x50, 0x12, 0x52),   # 10 purple dark
    (0x2c, 0x20, 0x16),   # 11 lamp off
    (0xff, 0xb4, 0x30),   # 12 lamp lit          (live only)
    (0xb8, 0x62, 0x16),   # 13 lamp glow         (live only)
    (0xf4, 0xe8, 0xd0),   # 14 paddle light end  (live only)
    (0x30, 0x2e, 0x34),   # 15 knob body
]

# ---- geometry ----
P   = 18                      # column pitch
X0  = 24                      # left edge of bit 21's column
def colx(bit):                # centre x of the column for bit 21..0
    return X0 + (21 - bit) * P + P // 2
CX0 = X0 + 22 * P + 12        # left edge of the first control column
CP  = 28                      # control switch pitch
def ctlx(k):                  # centre x of control switch k = 0..6
    return CX0 + k * CP + CP // 2
Y_STA, Y_ADR, Y_DAT = 100, 162, 224       # lamp centres
Y_BAND_A, Y_BAND_D = 136, 198             # band tops
SP = 33                                    # status lamp pitch (own row, full width)
def stax(i):                               # status lamp i = 0..11, left to right
    return X0 + 15 + i * SP
Y_CAP, Y_PAD0, Y_PAD1 = 268, 296, 424     # switch cap top, paddle top/bottom
LEND = 26                                  # paddle light end height
LR = 5                                     # lamp radius
PH, PL = 84, 110                           # PARITY HIGH / LOW lamp centres (y = Y_DAT)
KA_C, KD_C = None, None                    # knob centres, set in draw()
STATUS = ['PAR|ERR', 'ADRS|ERR', 'RUN', 'PAUSE', 'MASTER', 'USER', 'SUPER', 'KERNEL',
          'DATA', '16', '18', '22']
# knob lamp grids, (label, knob position): rotary1_bin / rotary2_bin in rtl/paneldriver.vhd
KA = [(('USER D', 4), ('USER I', 5)), (('SUPER D', 3), ('SUPER I', 6)),
      (('KERNEL D', 2), ('KERNEL I', 7)), (('CONS PHY', 1), ('PROG PHY', 0))]
KD = [(('DATA|PATHS', 0), ('µADRS|FPP/CPU', 1)), (('BUS REG', 3), ('DISPLAY|REGISTER', 2))]
# pointer angle (degrees, anticlockwise from 3 o'clock) for each grid cell: an even dial,
# the left column of labels on the left of the knob, the right one on the right
KA_ANG = [(112.5, 67.5), (157.5, 22.5), (202.5, 337.5), (247.5, 292.5)]
KD_ANG = [(135, 45), (225, 315)]
CTL = [('LOAD ADRS', 7), ('EXAM', 9), ('DEP', 7), ('CONT', 9), ('ENABLE', 7), ('S INST', 9), ('START', 7)]
CTL_LOW = {4: 'HALT', 5: 'S BUS'}

LIT = {1: 12, 2: 13}
ART_WORDS = 28672                          # rtl/panel_view.sv's ROM size
def oid(kind, n):
    return kind << 7 | n

def grp_colour(bit, dark=False):
    red = (bit // 3) % 2 == 1
    return (8 if dark else 7) if red else (10 if dark else 9)

def draw(fdir):
    """-> (picture, object map), both 640 x 480"""
    im = Image.new('P', (W, H), 0)
    im.putpalette([c for rgb in PAL for c in rgb])
    om = Image.new('I', (W, H), 0)
    d = ImageDraw.Draw(im)
    o = ImageDraw.Draw(om)
    d.fontmode = '1'                         # no anti-aliasing: crisp, 1 colour
    f6  = ImageFont.truetype(fdir + '/DejaVuSansCondensed-Bold.ttf', 7)
    f7  = ImageFont.truetype(fdir + '/DejaVuSansCondensed-Bold.ttf', 8)
    f8  = ImageFont.truetype(fdir + '/DejaVuSansCondensed-Bold.ttf', 9)
    flogo = ImageFont.truetype(fdir + '/DejaVuSans-Bold.ttf', 30)
    fdec  = ImageFont.truetype(fdir + '/DejaVuSans.ttf', 11)
    fdecb = ImageFont.truetype(fdir + '/DejaVuSans-Bold.ttf', 15)

    def text_c(x, y, s, f, fill=4):          # centred, '|' = new line
        hh = f.getbbox('A')[3] + 1
        for i, l in enumerate(s.split('|')):
            w = d.textlength(l, font=f)
            d.text((round(x - w / 2), y + i * hh), l, font=f, fill=fill)
    def text_l(x, y, s, f, fill=4):
        hh = f.getbbox('A')[3] + 1
        for i, l in enumerate(s.split('|')):
            d.text((x, y + i * hh), l, font=f, fill=fill)

    # DEC strip above the panel
    x = 14
    for ch in 'digital':
        d.rectangle((x, 8, x + 15, 24), outline=1, width=1)
        w = d.textlength(ch, font=fdecb)
        d.text((x + 8 - w / 2, 7), ch, font=fdecb, fill=6)
        x += 17
    tag = 'digital equipment corporation • maynard, massachusetts'
    d.text((x + 8, 11), tag, font=fdec, fill=6)
    d.rounded_rectangle((8, 4, x + 16 + d.textlength(tag, font=fdec), 28), radius=4, outline=1, width=1)

    # the panel
    d.rounded_rectangle((6, 34, W - 7, 452), radius=14, fill=2)

    # logo: "pdp" and "/70" outlined, "11" solid. The letters of "pdp" are
    # placed one by one so that neighbouring outlines coincide and read as one
    # shared line: all outlines (white) first, then the interiors (panel
    # black), so no interior covers a shared stroke.
    SW = 2                                    # outline width
    def ink(ch):                              # columns the glyph and its outline really cover,
        t = Image.new('1', (80, 80), 0)       # relative to its origin
        ImageDraw.Draw(t).text((20, 10), ch, font=flogo, fill=1, stroke_width=SW, stroke_fill=1)
        cols = [x for x in range(80) if any(t.getpixel((x, y)) for y in range(80))]
        return cols[0] - 20, cols[-1] - 20
    lx, ly = 22, 38
    glyphs = []                               # (x, text, solid)
    x = lx
    for i, ch in enumerate('pdp'):
        if i:                                 # left outline on the previous letter's right outline
            prev = glyphs[-1]
            x = prev[0] + ink(prev[1])[1] - ink(ch)[0] - (SW - 1)
        glyphs.append((x, ch, False))
    x = glyphs[-1][0] + d.textlength('p', font=flogo) - 2
    for part, solid in (('11', True), ('/70', False)):
        glyphs.append((x, part, solid))
        x += d.textlength(part, font=flogo) - 2
    for gx, ch, solid in glyphs:              # pass 1: outlines
        d.text((gx, ly), ch, font=flogo, fill=4, stroke_width=0 if solid else SW, stroke_fill=4)
    for gx, ch, solid in glyphs:              # pass 2: interiors of the outlined letters
        if not solid:
            d.text((gx, ly), ch, font=flogo, fill=2)

    # status row: its own window across the full width, one label per lamp
    d.rounded_rectangle((X0, 75, colx(0) + P // 2, Y_STA + 11), radius=4, fill=3)
    for i, lab in enumerate(STATUS):
        text_c(stax(i), 79 if '|' in lab else 84, lab, f6)
    for i in (1, 4, 7, 8):                    # PAR ADRS | RUN PAUSE MASTER | USER SUPER KERNEL | DATA | 16 18 22
        xb = (stax(i) + stax(i + 1)) // 2
        d.line((xb, 78, xb, Y_STA + 8), fill=6)
    text_c(stax(10), 66, 'ADDRESSING', f6, fill=5)

    # ADDRESS and DATA bands and lamp windows
    def band(y, bits, label):
        for b in bits:
            x0 = colx(b) - P // 2
            d.rectangle((x0, y, x0 + P - 1, y + 5), fill=grp_colour(b))
        w = d.textlength(label, font=f8)
        d.text((colx(bits[-1]) + P // 2 - w - 3, y - 11), label, font=f8, fill=4)
        x0, x1 = colx(bits[0]) - P // 2, colx(bits[-1]) + P // 2 - 1
        d.rectangle((x0, y + 6, x1, y + 6 + 40), fill=3)
        for b in bits[1:]:
            xb = colx(b) - P // 2
            d.line((xb, y + 6, xb, y + 46), fill=2)
    band(Y_BAND_A, list(range(21, -1, -1)), 'ADDRESS')
    band(Y_BAND_D, list(range(15, -1, -1)), 'DATA')

    # key switch and parity lamps (left of the DATA row)
    kx, ky = 40, 226
    text_l(14, 198, 'POWER', f7); text_l(48, 198, 'LOCK', f7); text_l(14, 246, 'OFF', f7)
    d.ellipse((kx - 11, ky - 11, kx + 11, ky + 11), fill=5)
    d.ellipse((kx - 8, ky - 8, kx + 8, ky + 8), fill=6)
    d.line((kx - 6, ky + 6, kx + 6, ky - 6), fill=4, width=3)
    d.rounded_rectangle((PH - 14, 198, PL + 14, Y_DAT + 12), radius=3, fill=3)
    text_c((PH + PL) // 2, 201, 'PARITY', f7)
    text_c(PH, 211, 'HIGH', f6); text_c(PL, 211, 'LOW', f6)

    # knobs: lamp grids and bodies; pointers are objects
    def lamp(x, y, r, n):                    # an unlit lamp; its core and glow ring as objects
        d.ellipse((x - r, y - r, x + r, y + r), fill=11)
        o.ellipse((x - r - 1, y - r - 1, x + r + 1, y + r + 1), fill=oid(2, n))
        o.ellipse((x - r + 1, y - r + 1, x + r - 1, y + r - 1), fill=oid(1, n))
    def knob_block(y0, y1, rows, angs, kc, lamp0, ptr0):
        x0, x1 = CX0 - 2, ctlx(6) + CP // 2 + 2
        d.rounded_rectangle((x0, y0, x1, y1), radius=6, fill=3)
        for r, row in enumerate(rows):
            yy = y0 + 8 + r * ((y1 - y0 - 14) // len(rows))
            for c, (lab, pos) in enumerate(row):
                lxp = x0 + 10 + c * 58
                lamp(lxp, yy + 4, 3, lamp0 + pos)
                text_l(lxp + 7, yy, lab, f7)
        cx, cy = kc
        d.ellipse((cx - 15, cy - 15, cx + 15, cy + 15), fill=15, outline=5)
        taken = {}
        for r, row in enumerate(rows):
            for c, (lab, pos) in enumerate(row):
                a = math.radians(angs[r][c])
                t = Image.new('1', (W, H), 0)
                ImageDraw.Draw(t).line((cx + 5 * math.cos(a), cy - 5 * math.sin(a),
                                        cx + 13 * math.cos(a), cy - 13 * math.sin(a)), fill=1, width=3)
                for yy in range(cy - 14, cy + 15):
                    for xx in range(cx - 14, cx + 15):
                        if t.getpixel((xx, yy)):
                            if (xx, yy) in taken:   # two pointers may not share a pixel: neither gets it
                                om.putpixel((xx, yy), 0)
                            else:
                                taken[(xx, yy)] = pos
                                om.putpixel((xx, yy), oid(3, ptr0 + pos))
    global KA_C, KD_C
    KA_C, KD_C = (ctlx(6) - 4, 113), (ctlx(6) - 4, 220)
    knob_block(44, 182, KA, KA_ANG, KA_C, 52, 64)
    knob_block(194, 246, KD, KD_ANG, KD_C, 60, 72)

    # switches: number caps and paddles; the light ends are objects
    def paddle(x, hw, colr, up_n, dn_n):
        d.rectangle((x - hw, Y_PAD0, x + hw, Y_PAD1), fill=colr)
        o.rectangle((x - hw, Y_PAD0, x + hw, Y_PAD0 + LEND - 1), fill=oid(3, up_n))
        o.rectangle((x - hw, Y_PAD1 - LEND + 1, x + hw, Y_PAD1), fill=oid(3, dn_n))
    for b in range(21, -1, -1):
        x = colx(b)
        d.rounded_rectangle((x - 7, Y_CAP, x + 7, Y_CAP + 22), radius=3, fill=grp_colour(b))
        text_c(x, Y_CAP + 6, str(b), f8)
        paddle(x, 6, grp_colour(b, dark=True), b, 32 + b)
    for k, (lab, colr) in enumerate(CTL):
        x = ctlx(k)
        d.rounded_rectangle((x - 12, Y_CAP - 8, x + 12, Y_CAP + 22), radius=3, fill=colr)
        lab = lab.replace(' ', '|')
        text_c(x, Y_CAP - 3 if '|' in lab else Y_CAP + 4, lab, f6)
        paddle(x, 8, colr + 1, 22 + k, 54 + k)
        if k in CTL_LOW:
            text_c(x, Y_PAD1 + 6, CTL_LOW[k].replace(' ', '|'), f6)

    # the lamps
    for b in range(22): lamp(colx(b), Y_ADR, LR, b)
    for b in range(16): lamp(colx(b), Y_DAT, LR, 22 + b)
    for i in range(12): lamp(stax(i), Y_STA, LR, 38 + i)
    lamp(PH, Y_DAT, LR, 50); lamp(PL, Y_DAT, LR, 51)
    return im, om

# ---- the live state -----------------------------------------------------------
# stat_l from rtl/paneldriver.vhd: run pause master user super kernel data 16 18 22 adrserr par (11..0)
STAT_BIT = [0, 1, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2]     # status lamp i, left to right -> stat_l bit

def active(ob, st):
    kind, n = ob >> 7, ob & 127
    if kind in (1, 2):
        if n < 22: return st['addr'] >> n & 1
        if n < 38: return st['data'] >> (n - 22) & 1
        if n < 50: return st['stat'] >> STAT_BIT[n - 38] & 1
        if n < 52: return st['par'] >> (51 - n) & 1          # par[1] HIGH, par[0] LOW
        if n < 60: return st['ka'] == n - 52
        return st['kd'] == n - 60
    if n >= 72: return st['kd'] == n - 72
    if n >= 64: return st['ka'] == n - 64
    up = n < 32
    m = n if up else n - 32
    v = st['sw'] >> m & 1 if m < 22 else st['ctl'] >> (6 - (m - 22)) & 1   # ctl[6] LOAD ADRS ... ctl[0] START
    return v if up else 1 - v

def render(im, om, st):
    out = im.copy()
    pi, po, pd = im.load(), om.load(), out.load()
    for y in range(H):
        for x in range(W):
            ob = po[x, y]
            if ob and active(ob, st):
                kind, n = ob >> 7, ob & 127
                pd[x, y] = LIT[kind] if kind in LIT else (4 if n >= 64 else 14)
    return out

def runs(im, om):
    pi, po = im.load(), om.load()
    words = []
    for y in range(H):
        x = 0
        while x < W:
            c, ob = pi[x, y], po[x, y]
            n = 1
            while x + n < W and n < 128 and pi[x + n, y] == c and po[x + n, y] == ob:
                n += 1
            words.append(c << 16 | ob << 7 | (n - 1))
            x += n
    return words

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('fontdir')
    ap.add_argument('--hex'); ap.add_argument('--png')
    ap.add_argument('--state', type=int, help='random live state from this seed (for --png/--check)')
    ap.add_argument('--state-out'); ap.add_argument('--check')
    a = ap.parse_args()
    im, om = draw(a.fontdir)
    if a.hex:
        w = runs(im, om)
        assert len(w) <= ART_WORDS, 'the runs do not fit in panel_view.sv ART_WORDS'
        with open(a.hex, 'w') as f:
            for v in w + [0] * (ART_WORDS - len(w)): f.write('%05x\n' % v)
        print('%s: %d runs (%d bits)' % (a.hex, len(w), len(w) * 20))
    st = dict(addr=0, data=0, stat=0, par=0, sw=0, ctl=0, ka=0, kd=0)
    if a.state is not None:
        r = random.Random(a.state)
        st = dict(addr=r.getrandbits(22), data=r.getrandbits(16), stat=r.getrandbits(12), par=r.getrandbits(2),
                  sw=r.getrandbits(22), ctl=r.getrandbits(7), ka=r.randrange(8), kd=r.randrange(4))
    if a.state_out:
        with open(a.state_out, 'w') as f:
            f.write(' '.join('+%s=%x' % (k, v) for k, v in st.items()) + '\n')
    pic = render(im, om, st)
    if a.png:
        pic.save(a.png)
    if a.check:
        sim = Image.open(a.check).convert('RGB').load()
        want = pic.convert('RGB').load()
        bad = [(x, y) for y in range(H) for x in range(W) if sim[x, y] != want[x, y]]
        print('check %s: %d of %d pixels differ%s' % (a.check, len(bad), W * H,
              (', first at %s: sim %s want %s' % (bad[0], sim[bad[0]], want[bad[0]])) if bad else ''))
        sys.exit(1 if bad else 0)

main()
