#!/usr/bin/env python3
"""Generates the layer SVGs of Resources/Icons/Alternates/hat.icon (Icon Composer package), the `app-icon=hat`
alternate. It was the bundle icon until 2026-10; the bundle icon (Resources/Icons/AppIcon.icon) now comes from a
separate image lab.

The artwork is flat and drawn from scratch: a wide-brimmed hat with a long feather and a bare shoulder, under a
glass loupe whose lens shows the same shapes as large square pixels. The lens pixels are sampled from a render of the artwork layer, so the script needs Xcode's Icon Composer
(ictool) and ImageMagick (`magick`).

Usage: scripts/make-icon-art.py [--variant a|b|c] [--out DIR.icon]
Variant a (loupe lower-right over the feather) is the shipped one; b and c were the alternative sketches.
"""
import argparse, json, math, os, shutil, subprocess, sys, tempfile

ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
S = 1024

# Loupe placement per variant: lens centre, lens radius, art transform (scale about a point, then translate).
VARIANTS = {
    "a": dict(lens=(712, 668), r=178, art=None),
    "b": dict(lens=(470, 330), r=200, art=None),
    "c": dict(lens=(820, 560), r=210, art=(1.75, (560, 420), (512, 470))),
}

def feather_path():
    """A long plume hanging from the right of the hat: tapered body with a zigzag fringe."""
    def spine(t):  # cubic bezier
        p0, p1, p2, p3 = (680, 300), (810, 430), (830, 700), (700, 1060)
        u = 1 - t
        x = u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0]
        y = u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1]
        return x, y
    n = 44
    left, right, spine_pts = [], [], []
    for i in range(n + 1):
        t = i / n
        x, y = spine(t)
        x2, y2 = spine(min(1, t + 0.01)) if t < 1 else spine(t)
        x1, y1 = spine(max(0, t - 0.01))
        dx, dy = x2 - x1, y2 - y1
        L = math.hypot(dx, dy) or 1
        nx, ny = -dy / L, dx / L
        w = 18 + 105 * math.sin(math.pi * min(1, t * 1.15)) ** 0.6
        jag = 1.0 if i % 2 == 0 else 0.72
        back = 16  # barbs sweep downwards
        left.append((x + nx * w * jag + dx / L * back * (i % 2), y + ny * w * jag + dy / L * back * (i % 2)))
        right.append((x - nx * w * jag + dx / L * back * (i % 2), y - ny * w * jag + dy / L * back * (i % 2)))
        spine_pts.append((x, y))
    pts = left + right[::-1]
    body = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts) + " Z"
    barbs = []
    for i in range(2, n - 1, 2):
        (sx, sy), (lx, ly), (rx, ry) = spine_pts[i], left[i + 1], right[i + 1]
        barbs.append(f"M{sx:.1f},{sy:.1f} Q{(sx+lx)/2:.1f},{(sy+ly)/2+8:.1f} {lx*0.82+sx*0.18:.1f},{ly*0.82+sy*0.18:.1f}")
        barbs.append(f"M{sx:.1f},{sy:.1f} Q{(sx+rx)/2:.1f},{(sy+ry)/2+8:.1f} {rx*0.82+sx*0.18:.1f},{ry*0.82+sy*0.18:.1f}")
    shaft = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in spine_pts[:-4])
    return body, " ".join(barbs), shaft

def art_svg(transform):
    body, barbs, shaft = feather_path()
    g = ""
    if transform:
        k, (cx, cy), (tx, ty) = transform
        g = f' transform="translate({tx} {ty}) scale({k}) translate({-cx} {-cy})"'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">
      <stop offset="0" stop-color="#E9C08F"/><stop offset="1" stop-color="#C27A6C"/>
    </linearGradient>
  </defs>
  <rect width="{S}" height="{S}" fill="url(#bg)"/>
  <g{g}>
    <rect x="-200" y="-200" width="330" height="1500" fill="#B8786A" opacity="0.55"/>
    <rect x="130" y="-200" width="26" height="1500" fill="#F2D3A6" opacity="0.45"/>
    <!-- hair behind the face -->
    <path d="M300,380 C250,520 270,700 330,820 L470,820 C430,700 420,520 450,380 Z" fill="#6A3A2E"/>
    <path d="M560,370 C630,470 640,640 620,840 L720,860 C740,640 710,450 650,350 Z" fill="#5E3228"/>
    <!-- bare shoulder and neck -->
    <path d="M-60,800 C80,700 260,690 400,730 C470,750 520,800 560,880 L640,1300 L-60,1300 Z" fill="#E7AE91"/>
    <path d="M440,560 L556,540 C552,660 556,760 590,860 C520,820 450,800 400,780 C430,720 444,650 440,560 Z" fill="#DE9F84"/>
    <path d="M150,760 C230,730 320,730 400,760" fill="none" stroke="#C9846C" stroke-width="10" stroke-linecap="round" opacity="0.7"/>
    <!-- face (no features), half in the brim's shade -->
    <path d="M400,360 C390,470 410,560 470,620 C520,650 570,600 585,520 C595,460 590,400 575,360 Z" fill="#EDB89C"/>
    <path d="M396,360 L580,360 C585,400 588,420 586,440 C520,420 450,425 398,450 Z" fill="#C98B74" opacity="0.8"/>
    <!-- hat: brim underside, brim, crown, band -->
    <ellipse cx="470" cy="340" rx="410" ry="112" transform="rotate(-9 470 340)" fill="#A66F3A"/>
    <ellipse cx="470" cy="318" rx="404" ry="100" transform="rotate(-9 470 318)" fill="#E6B565"/>
    <ellipse cx="470" cy="312" rx="330" ry="70" transform="rotate(-9 470 312)" fill="#EDC27A" opacity="0.6"/>
    <path d="M330,300 C320,170 420,110 500,112 C590,114 650,170 640,262 C560,300 420,320 330,300 Z" fill="#CF9446"/>
    <path d="M333,270 C430,288 560,268 642,232 L640,266 C560,302 420,322 331,302 Z" fill="#8A3F3A"/>
    <path d="M390,170 C430,140 480,132 520,138" fill="none" stroke="#E8B868" stroke-width="12" stroke-linecap="round" opacity="0.7"/>
    <!-- feather -->
    <path d="{body}" fill="#9C5577"/>
    <path d="{barbs}" fill="none" stroke="#C6869F" stroke-width="7" stroke-linecap="round"/>
    <path d="{shaft}" fill="none" stroke="#EBC9C4" stroke-width="7" stroke-linecap="round"/>
  </g>
</svg>
'''

def loupe_geometry(v):
    (cx, cy), r = v["lens"], v["r"]
    ring = 30
    ang = math.radians(45)
    hx0, hy0 = cx + (r + ring * 0.6) * math.cos(ang), cy + (r + ring * 0.6) * math.sin(ang)
    hlen = 165
    hx1, hy1 = hx0 + hlen * math.cos(ang), hy0 + hlen * math.sin(ang)
    return cx, cy, r, ring, (hx0, hy0, hx1, hy1)

def frame_svg(v):
    cx, cy, r, ring, (hx0, hy0, hx1, hy1) = loupe_geometry(v)
    ro = r + ring
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <line x1="{hx0:.1f}" y1="{hy0:.1f}" x2="{hx1:.1f}" y2="{hy1:.1f}" stroke="#2E2A2E" stroke-width="66" stroke-linecap="round"/>
  <path fill-rule="evenodd" fill="#3A3438" d="M{cx-ro},{cy} a{ro},{ro} 0 1,0 {2*ro},0 a{ro},{ro} 0 1,0 {-2*ro},0 Z M{cx-r},{cy} a{r},{r} 0 1,0 {2*r},0 a{r},{r} 0 1,0 {-2*r},0 Z"/>
</svg>
'''

def lens_svg(v, cells, n, block, mag_origin):
    cx, cy, r, *_ = loupe_geometry(v)
    x0, y0 = mag_origin
    rects = []
    for j in range(n):
        for i in range(n):
            rects.append(f'<rect x="{x0 + i*block:.1f}" y="{y0 + j*block:.1f}" width="{block+0.6:.1f}" height="{block+0.6:.1f}" fill="{cells[j][i]}"/>')
    grid = []
    for k in range(n + 1):
        grid.append(f'M{x0 + k*block:.1f},{y0:.1f} v{n*block:.1f}')
        grid.append(f'M{x0:.1f},{y0 + k*block:.1f} h{n*block:.1f}')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs><clipPath id="lens"><circle cx="{cx}" cy="{cy}" r="{r + 2}"/></clipPath></defs>
  <g clip-path="url(#lens)">
    {"".join(rects)}
    <path d="{" ".join(grid)}" stroke="#000000" stroke-opacity="0.16" stroke-width="3" fill="none"/>
  </g>
</svg>
'''

def icon_json(with_loupe=True):
    groups = []
    if with_loupe:
        groups.append({
            "layers": [{"image-name": "frame.svg", "name": "frame", "glass": True}],
            "shadow": {"kind": "neutral", "opacity": 0.55},
            "translucency": {"enabled": True, "value": 0.25},
            "specular": True,
        })
        groups.append({
            "layers": [{"image-name": "lens.svg", "name": "lens", "glass": True}],
            "translucency": {"enabled": False, "value": 0.0},
            "shadow": {"kind": "neutral", "opacity": 0.35},
            "specular": True,
        })
    groups.append({"layers": [{"image-name": "art.svg", "name": "art", "glass": False}],
                   "shadow": {"kind": "none", "opacity": 0.5}, "specular": False})
    return {"fill": {"solid": "srgb:0.91373,0.75294,0.56078,1.00000"}, "groups": groups,
            "supported-platforms": {"squares": ["macOS"]}}

def write_icon(path, files, with_loupe=True):
    if os.path.exists(path):
        shutil.rmtree(path)
    os.makedirs(os.path.join(path, "Assets"))
    for name, text in files.items():
        with open(os.path.join(path, "Assets", name), "w") as f:
            f.write(text)
    with open(os.path.join(path, "icon.json"), "w") as f:
        json.dump(icon_json(with_loupe), f, indent=2)
        f.write("\n")

def sample(png, x, y, side, n):
    out = subprocess.run(["magick", png, "-crop", f"{side}x{side}+{x}+{y}", "+repage", "-filter", "box",
                          "-resize", f"{n}x{n}!", "-depth", "8", "txt:-"], check=True, capture_output=True, text=True).stdout
    cells = [[None] * n for _ in range(n)]
    for line in out.splitlines():
        if line.startswith("#"):
            continue
        pos, rest = line.split(":", 1)
        i, j = map(int, pos.split(","))
        cells[j][i] = rest.split()[1][:7]
    return cells

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="a", choices=VARIANTS)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "Resources", "Icons", "Alternates", "hat.icon"))
    a = ap.parse_args()
    v = VARIANTS[a.variant]
    art = art_svg(v["art"])
    with tempfile.TemporaryDirectory() as tmp:
        probe = os.path.join(tmp, "Art.icon")
        write_icon(probe, {"art.svg": art}, with_loupe=False)
        png = os.path.join(tmp, "art.png")
        subprocess.run([ICTOOL, probe, "--export-image", "--output-file", png, "--platform", "macOS",
                        "--rendition", "Default", "--width", str(S), "--height", str(S), "--scale", "1"],
                       check=True, capture_output=True)
        cx, cy, r, *_ = loupe_geometry(v)
        n, mag = 7, 1.6
        block = 2 * r / (n - 1)          # 7 cells over the diameter, the outer ones clipped by the rim
        span = n * block                  # lens-space width of the grid
        side = int(round(span / mag))     # source width
        cells = sample(png, int(cx - side / 2), int(cy - side / 2), side, n)
        lens = lens_svg(v, cells, n, block, (cx - span / 2, cy - span / 2))
    write_icon(a.out, {"art.svg": art, "lens.svg": lens, "frame.svg": frame_svg(v)})
    print(f"wrote {os.path.normpath(a.out)}")

if __name__ == "__main__":
    sys.exit(main())
