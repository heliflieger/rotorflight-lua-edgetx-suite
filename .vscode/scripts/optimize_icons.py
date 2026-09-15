#!/usr/bin/env python3
"""
Pre-scales and optimizes tile and theme icon assets to 40x40 pixels.

EdgeTX LVGL allocates contiguous C-heap memory (w * h * 4 bytes) during PNG decode via stbi_load.
Pre-scaling 70x70+ icons to 40x40 reduces heap pressure by ~3x (19.6 kB -> 6.4 kB per decode)
and allows 800x480 displays to render icons without software zoom passes.
"""

import os
import sys
from PIL import Image

WORKSPACE_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

def resize_icon(image_path, target_size=(40, 40)):
    try:
        orig = Image.open(image_path)
    except Exception as e:
        print(f"Error opening {image_path}: {e}")
        return False, None, 0

    w, h = orig.size
    if w == target_size[0] and h == target_size[1]:
        return False, orig.size, os.path.getsize(image_path)

    has_alpha = "transparency" in orig.info or orig.mode in ("RGBA", "LA")
    img = orig.convert("RGBA" if has_alpha else "RGB")

    if w == h:
        resized = img.resize(target_size, Image.Resampling.LANCZOS)
    else:
        scale = min(target_size[0] / w, target_size[1] / h)
        nw, nh = int(round(w * scale)), int(round(h * scale))
        fitted = img.resize((nw, nh), Image.Resampling.LANCZOS)

        bg_color = img.getpixel((0, 0))
        if has_alpha:
            canvas = Image.new("RGBA", target_size, (0, 0, 0, 0))
        else:
            canvas = Image.new("RGB", target_size, bg_color)

        px = (target_size[0] - nw) // 2
        py = (target_size[1] - nh) // 2
        canvas.paste(fitted, (px, py), fitted if has_alpha else None)
        resized = canvas

    candidates = []

    # Candidate 1: RGB / RGBA
    tmp1 = image_path + ".tmp1"
    resized.save(tmp1, "PNG", optimize=True)
    candidates.append((os.path.getsize(tmp1), tmp1))

    # Candidate 2: Quantized palette (if non-alpha)
    tmp2 = image_path + ".tmp2"
    if not has_alpha:
        try:
            pal = resized.quantize(colors=64, method=Image.Quantize.MEDIANCUT)
            pal.save(tmp2, "PNG", optimize=True)
            candidates.append((os.path.getsize(tmp2), tmp2))
        except Exception:
            pass

    # Candidate 3: Grayscale (if monochromatic)
    tmp3 = image_path + ".tmp3"
    if not has_alpha:
        try:
            rgb = resized.convert("RGB")
            is_gray = all(p[0] == p[1] == p[2] for p in rgb.getdata())
            if is_gray:
                gray = rgb.convert("L")
                gray.save(tmp3, "PNG", optimize=True)
                candidates.append((os.path.getsize(tmp3), tmp3))
        except Exception:
            pass

    candidates.sort(key=lambda x: x[0])
    best_size, best_tmp = candidates[0]

    orig.close()
    if os.path.exists(image_path):
        os.remove(image_path)
    os.rename(best_tmp, image_path)

    for _, tmp in candidates:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except Exception:
                pass

    return True, (w, h), best_size

def process_directories(directories):
    total_before = 0
    total_after = 0
    processed_count = 0

    for d in directories:
        full_d = os.path.join(WORKSPACE_ROOT, d) if not os.path.isabs(d) else d
        if not os.path.isdir(full_d):
            continue
        for root, _, files in os.walk(full_d):
            for f in sorted(files):
                if f.endswith(".png"):
                    p = os.path.join(root, f)
                    before_sz = os.path.getsize(p)
                    total_before += before_sz
                    changed, old_size, after_sz = resize_icon(p)
                    total_after += after_sz
                    if changed:
                        processed_count += 1
                        rel = os.path.relpath(p, WORKSPACE_ROOT).replace("\\", "/")
                        print(f"Resized: {rel:70s} {old_size[0]}x{old_size[1]} ({before_sz:5d} B) -> 40x40 ({after_sz:5d} B)")

    print(f"\nDone! Processed {processed_count} icons.")
    print(f"Total size before: {total_before:,} bytes")
    print(f"Total size after:  {total_after:,} bytes")
    print(f"Savings:           {total_before - total_after:,} bytes")

if __name__ == "__main__":
    dirs = [
        os.path.join("src", "rfsuite", "app", "pages"),
        os.path.join("src", "rfsuite", "widgets", "dashboard", "themes")
    ]
    process_directories(dirs)
