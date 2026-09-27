#!/usr/bin/env python3
"""contact-sheet.py — lay a capture burst out as one labelled image.

    contact-sheet.py FRAMEDIR PREFIX OUT.png [--crop X,Y,W,H] [--scale S] [--cols N]

PREFIX selects the frames: every FRAMEDIR/PREFIX*.png in name order, so
`dashboard` takes the open burst, the settled frame and the close burst
together, and `dashboard-open` takes only the opening. Each tile is labelled
with its file stem so a sheet read months later still says which frame is
which.

Used to compare the shell before and after a change, and to hand a reviewer
one image instead of forty.
"""
import argparse
import glob
import os
import sys

from PIL import Image, ImageDraw, ImageFont


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("framedir")
    ap.add_argument("prefix")
    ap.add_argument("out")
    ap.add_argument("--crop", default="")
    ap.add_argument("--scale", type=float, default=0.5)
    ap.add_argument("--cols", type=int, default=5)
    a = ap.parse_args()

    files = sorted(glob.glob(os.path.join(a.framedir, a.prefix + "*.png")))
    # "-settled" sorts after "-open-NN" and before nothing useful, so place it
    # explicitly between the open and close bursts.
    opens = [f for f in files if "-open-" in f]
    settled = [f for f in files if f.endswith("-settled.png")]
    closes = [f for f in files if "-close-" in f]
    rest = [f for f in files if f not in opens + settled + closes]
    files = opens + settled + closes + rest
    if not files:
        print("no frames match", a.prefix, file=sys.stderr)
        return 1

    crop = tuple(int(v) for v in a.crop.split(",")) if a.crop else None
    tiles = []
    for f in files:
        im = Image.open(f).convert("RGB")
        if crop:
            x, y, w, h = crop
            im = im.crop((x, y, x + w, y + h))
        if a.scale != 1.0:
            im = im.resize((max(1, int(im.width * a.scale)), max(1, int(im.height * a.scale))),
                           Image.LANCZOS)
        tiles.append((os.path.splitext(os.path.basename(f))[0], im))

    tw = max(t.width for _, t in tiles)
    th = max(t.height for _, t in tiles)
    label_h = 18
    cols = max(1, min(a.cols, len(tiles)))
    rows = (len(tiles) + cols - 1) // cols
    pad = 6
    sheet = Image.new("RGB", (cols * (tw + pad) + pad, rows * (th + label_h + pad) + pad), (40, 40, 40))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 12)
    except OSError:
        font = ImageFont.load_default()
    for i, (name, im) in enumerate(tiles):
        r, c = divmod(i, cols)
        x = pad + c * (tw + pad)
        y = pad + r * (th + label_h + pad)
        draw.text((x + 2, y + 2), name, fill=(230, 230, 230), font=font)
        sheet.paste(im, (x, y + label_h))
    sheet.save(a.out)
    print(a.out, f"{len(tiles)} frames")
    return 0


if __name__ == "__main__":
    sys.exit(main())
