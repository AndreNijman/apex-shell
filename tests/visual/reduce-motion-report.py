#!/usr/bin/env python3
# reduce-motion-report.py OUTDIR — Reduce Motion as its own mode (UI/UX roadmap
# v3 Phase 21), read off a capture made with
#     CAPTURE_REDUCED=true CAPTURE_FRAMES=9 CAPTURE_SPAN_MS=400 tests/visual/capture-surfaces.sh OUTDIR …
# For each surface, every open and close frame: its footprint against the
# empty desk and how strongly it shows. Under Reduce Motion the footprint must
# be the settled one whenever the surface shows at all — it fades, it does
# not grow, slide or travel. Known and intended: the right panel drops its
# in-bar band at once on a reduced close (Δ ≈ the notch height), and a
# full-screen scrim reads smaller than it is below the diff threshold.
import sys, glob, re
from PIL import Image, ImageChops

d = sys.argv[1]
def load(p): return Image.open(p).convert("RGB")
def bbox_of(img, ref, thr=40):
    diff = ImageChops.difference(img, ref).convert("L").point(lambda v: 255 if v > thr else 0)
    return diff.getbbox()
def strength(img, ref, box):
    if not box: return 0.0
    a = ImageChops.difference(img.crop(box), ref.crop(box)).convert("L")
    h = a.histogram(); n = sum(h)
    return sum(i * c for i, c in enumerate(h)) / max(1, n)

surfaces = sorted({re.sub(r"-(warm|cold)-.*", "", p.split("/")[-1])
                   for p in glob.glob(f"{d}/*-warm-open-*.png")})
bad = []
for s in surfaces:
    opens = sorted(glob.glob(f"{d}/{s}-warm-open-*.png"))
    closes = sorted(glob.glob(f"{d}/{s}-warm-close-*.png"))
    settled = f"{d}/{s}-warm-settled.png"
    if not (opens and closes): continue
    rest = load(closes[-1])
    fin = load(settled) if glob.glob(settled) else load(opens[-1])
    fbox = bbox_of(fin, rest)
    fstr = strength(fin, rest, fbox) or 1
    line = []
    for tag, frames in (("open", opens), ("close", closes)):
        for p in frames:
            t = re.search(r"-(\d+)ms", p).group(1).lstrip("0") or "0"
            img = load(p); box = bbox_of(img, rest)
            st = 100 * strength(img, rest, fbox) / fstr
            if box and fbox and st > 15:
                dw = abs((box[2]-box[0]) - (fbox[2]-fbox[0])); dh = abs((box[3]-box[1]) - (fbox[3]-fbox[1]))
                dx = abs(box[0]-fbox[0]); dy = abs(box[1]-fbox[1])
                moved = max(dw, dh, dx, dy)
            else:
                moved = 0
            line.append(f"{tag[0]}{t}:{st:.0f}%" + (f"/Δ{moved}" if moved > 12 else ""))
            if moved > 12: bad.append((s, tag, t, moved, round(st)))
    print(f"{s:14} settled {fbox}\n    " + " ".join(line))
print("\nMOVED (footprint off the settled one by > 12 px while showing > 15 %):")
for b in bad: print("   ", b)
if not bad: print("    none")
