#!/usr/bin/env python3
"""Exports the animated Vesalius mark from vesalius-mark.html (the single source of truth):
frames via one headless Chrome, then vesalius-mark.mp4, vesalius-mark.gif, vesalius-mark.png (still),
vesalius-mark.svg (vector) and a contact sheet. Requires Google Chrome, ffmpeg and Pillow.

Usage: export_mark.py [--out <dir>] [--work <scratch dir>]
"""
import argparse, base64, os, re, subprocess, time

HERE = os.path.dirname(os.path.abspath(__file__))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def dump(page, mode, work, size_hint=1000):
    """Runs the page in one headless Chrome with --dump-dom and returns the DOM text. Chrome can stay
    alive after writing the DOM, so a watchdog stops it once the output stops growing."""
    out = os.path.join(work, f"dump-{mode}.txt")
    with open(out, "w") as f:
        proc = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", f"--user-data-dir={work}/chrome-profile",
                                 "--dump-dom", f"file://{page}#{mode}"], stdout=f, stderr=subprocess.DEVNULL)
        last, stable = -1, 0
        while proc.poll() is None and stable < 3:
            time.sleep(1)
            size = os.path.getsize(out)
            stable = stable + 1 if size == last and size > size_hint else 0
            last = size
        proc.kill()
    return open(out).read()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=HERE)
    parser.add_argument("--work", default="/tmp/vesalius-mark-export")
    args = parser.parse_args()
    from PIL import Image, ImageDraw
    os.makedirs(os.path.join(args.work, "frames"), exist_ok=True)
    source = open(os.path.join(HERE, "vesalius-mark.html")).read()
    page = os.path.join(args.work, "mark.html")
    with open(page, "w") as f:  # fonts are not needed for frames
        f.write('<!doctype html><html><head><meta charset="utf-8"></head><body>'
                + "\n".join(l for l in source.splitlines() if "<link" not in l) + "</body></html>")

    pngs = re.findall(r"data:image/png;base64,([A-Za-z0-9+/=]+)", dump(page, "dump", args.work, 100000))
    for i, b in enumerate(pngs):
        open(os.path.join(args.work, "frames", f"f{i:03d}.png"), "wb").write(base64.b64decode(b))
    print(f"{len(pngs)} frames")

    frames = os.path.join(args.work, "frames", "f%03d.png")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "30", "-i", frames, "-vf", "scale=800:800",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "16", "-movflags", "+faststart",
                    os.path.join(args.out, "vesalius-mark.mp4")], check=True)
    palette = os.path.join(args.work, "palette.png")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "30", "-i", frames,
                    "-vf", "scale=480:480:flags=lanczos,palettegen=max_colors=128:stats_mode=full", palette], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "30", "-i", frames, "-i", palette,
                    "-lavfi", "scale=480:480:flags=lanczos[x];[x][1:v]paletteuse=dither=sierra2_4a", "-loop", "0",
                    os.path.join(args.out, "vesalius-mark.gif")], check=True)
    Image.open(os.path.join(args.work, "frames", "f150.png")).save(os.path.join(args.out, "vesalius-mark.png"))

    svg = re.search(r"<svg[\s\S]*</svg>", dump(page, "svg", args.work).replace("&lt;", "<").replace("&gt;", ">"))
    if svg:
        open(os.path.join(args.out, "vesalius-mark.svg"), "w").write(svg.group(0))

    picks = [6, 15, 24, 33, 42, 51, 60, 69, 78, 87, 96, 105, 114, 120, 126, 132, 141, 150, 162, 175, 190, 196, 202, 208]
    cw = 300
    sheet = Image.new("RGB", (6 * cw, 4 * cw), (11, 13, 18))
    draw = ImageDraw.Draw(sheet)
    for k, f in enumerate(p for p in picks if p < len(pngs)):
        im = Image.open(os.path.join(args.work, "frames", f"f{f:03d}.png")).convert("RGB").resize((cw, cw), Image.LANCZOS)
        sheet.paste(im, ((k % 6) * cw, (k // 6) * cw))
        draw.text(((k % 6) * cw + 8, (k // 6) * cw + 6), f"{f / 30:.1f}s", fill=(140, 147, 167))
    sheet.save(os.path.join(args.work, "contact-sheet.png"))
    print("wrote", ", ".join(n for n in sorted(os.listdir(args.out)) if n.startswith("vesalius-mark.")))


if __name__ == "__main__":
    main()
