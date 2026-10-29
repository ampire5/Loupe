# The view the custom detector's smart zoom would give each photo in each mode of detector.conf (docs/detector.md), from
# ModelBench's detections (TSV), as contact sheets: one per mode, each photo's view with the target and the zoom over
# Fit. Tunes detector.conf without building Loupe.
#   python sheets.py <detections.tsv> <photos dir> <out dir> [detector.conf]
# Vision's kinds are not run here: `face` stands for detector.conf's `heads` classes, the others are not found.
# The view: a 16:10 window, the target's frame (union of its parts, margin round, at least min-frame of the photo's
# long side) taking the mode's size of it on the side that binds, centred on the frame, kept inside the photo; never
# below Fit. Photos under 600 px (covers) are left out.
import csv, itertools, collections, sys, os, re
from PIL import Image, ImageDraw, ImageFont, ImageOps

pos = sys.argv[1:]
tsv, photos, out = pos[:3]
conf = pos[3] if len(pos) > 3 else os.path.expanduser('~/.config/loupe/detector.conf')
top, MODES, M, section = {}, {}, {}, None
for line in open(conf):
    line = line.split('#', 1)[0].strip()
    if not line: continue
    m = re.fullmatch(r'\[(.+)\]', line)
    if m:
        section = m.group(1).strip()
        if section != 'classes': MODES[section] = {}
        continue
    k, v = [x.strip() for x in line.split('=', 1)]
    if section == 'classes': M[k] = v.lower(); continue
    (MODES[section] if section else top)[k] = v
def share(v): return float(v.rstrip('%')) / 100 if v.endswith('%') else float(v)
REACH, MINF, MARGIN, SCORE = share(top['reach']), share(top['min-frame']), share(top['margin']), float(top['score'])
ASPECT = 16 / 10
HEADS = {h.strip() for h in top.get('heads', '').split(',') if h.strip()}

def head(x, y, w, h):
    W, H = w * 1.8, h * 1.8
    return (x + w / 2 - W / 2, y + h / 2 - H / 2 - h * 0.15, W, H)

def iou(a, b):
    ix = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])); iy = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    i = ix * iy
    return i / (a[2] * a[3] + b[2] * b[3] - i)

def union(rs):
    x0 = min(r[0] for r in rs); y0 = min(r[1] for r in rs)
    return (x0, y0, max(r[0] + r[2] for r in rs) - x0, max(r[1] + r[3] for r in rs) - y0)

parts = collections.defaultdict(lambda: collections.defaultdict(list))
names = set()
for r in csv.reader(open(tsv), delimiter='\t'):
    if not r or r[0].startswith('#') or r[0] == 'file': continue
    names.add(r[0])
    if len(r) < 8 or float(r[3]) < SCORE or r[2] not in M: continue
    k = M[r[2]]
    box = tuple(map(float, r[4:8]))
    if any(iou(box, o) > 0.5 for o in parts[r[0]][k]): continue   # the same part found whole and on a person's crop
    parts[r[0]][k].append(box)
    # Any face, as Vision's `face` would be (portrait mode).
    if k in HEADS and not any(iou(box, o) > 0.5 for o in parts[r[0]]['face']): parts[r[0]]['face'].append(box)

def target(p, chain, aspect):
    """The first target of `chain` found on photo p: its name and frame (normalised, before margin)."""
    for t in [s.strip() for s in chain.split(',')]:
        ks = t.split('+')
        if not all(parts[p][k] for k in ks): continue
        def rects(k): return [head(*b) if k in HEADS or k == 'face' else b for b in parts[p][k]]
        if len(ks) == 1:
            # The largest one, and others of its kind while all stay within reach.
            rs = sorted(rects(ks[0]), key=lambda b: -b[2] * b[3])
            chosen = [rs[0]]
            for b in rs[1:]:
                u = union(chosen + [b])
                if max(u[2], u[3]) <= REACH: chosen.append(b)
            return t, union(chosen)
        best = min((union(c) for c in itertools.product(*[rects(k) for k in ks])), key=lambda u: max(u[2], u[3]))
        if max(best[2], best[3]) <= REACH: return t, best
    return None, None

def view(frame, W, H, SIZE):
    """The view's rect in photo pixels."""
    x, y, w, h = frame[0] * W, frame[1] * H, frame[2] * W, frame[3] * H
    x, y, w, h = x - w * MARGIN, y - h * MARGIN, w * (1 + 2 * MARGIN), h * (1 + 2 * MARGIN)
    side = MINF * max(W, H)
    if max(w, h) < side:   # too small a frame: grown about its centre
        k = side / max(w, h); x, y, w, h = x + w / 2 - w * k / 2, y + h / 2 - h * k / 2, w * k, h * k
    vw = max(w / SIZE, h / SIZE * ASPECT); vh = vw / ASPECT
    fit = min(W / 1, H * ASPECT)   # the window's width in photo px at Fit
    if vw > fit: vw = fit; vh = vw / ASPECT
    cx = min(max(x + w / 2, vw / 2), W - vw / 2) if vw <= W else W / 2
    cy = min(max(y + h / 2, vh / 2), H - vh / 2) if vh <= H else H / 2
    return (cx - vw / 2, cy - vh / 2, vw, vh)

font = ImageFont.truetype('/System/Library/Fonts/Menlo.ttc', 18)
TW, TH = 480, 300
os.makedirs(out, exist_ok=True)
files = [f for f in sorted(names) if max(Image.open(os.path.join(photos, f)).size) >= 600]
summary = collections.defaultdict(collections.Counter)
for mode, m in MODES.items():
    chain, size = m['chain'], share(m['size'])
    cols = 4
    rows = (len(files) + cols - 1) // cols
    sheet = Image.new('RGB', (cols * (TW + 6), rows * (TH + 6)), (30, 30, 30))
    for n, f in enumerate(files):
        im = ImageOps.exif_transpose(Image.open(os.path.join(photos, f))).convert('RGB')
        W, H = im.size
        t, frame = target(f, chain, ASPECT)
        summary[mode][t or '— fit'] += 1
        if frame:
            v = view(frame, W, H, size)
            tile = Image.new('RGB', (TW, TH), (0, 0, 0))
            crop = im.crop((int(v[0]), int(v[1]), int(v[0] + v[2]), int(v[1] + v[3])))
            crop.thumbnail((TW, TH)); tile.paste(crop, ((TW - crop.width) // 2, (TH - crop.height) // 2))
            zoom = W / v[2] if W / H > ASPECT else (H * ASPECT) / v[2]   # over Fit
            label = f'{t}  ×{zoom:.1f}'
        else:
            tile = Image.new('RGB', (TW, TH), (0, 0, 0))
            c = im.copy(); c.thumbnail((TW, TH)); tile.paste(c, ((TW - c.width) // 2, (TH - c.height) // 2))
            label = '— fit'
        d = ImageDraw.Draw(tile)
        d.rectangle((0, TH - 26, TW, TH), fill=(0, 0, 0))
        d.text((6, TH - 24), f'{n + 1:02d} {label}', font=font, fill=(255, 255, 255))
        sheet.paste(tile, ((n % cols) * (TW + 6), (n // cols) * (TH + 6)))
    sheet.save(os.path.join(out, f'{mode}.jpg'), quality=82)
for mode in MODES:
    print(mode, dict(summary[mode].most_common()))
with open(os.path.join(out, 'index.txt'), 'w') as fh:
    for n, f in enumerate(files): fh.write(f'{n + 1:02d}\t{f}\n')
