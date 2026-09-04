"""真实截图的布局像素测量（无视觉能力时，用客观度量替代人工看图）。

输出：背景主色、内容包围盒、左右留白比例、行向内容带与空白带、信息密度。
用法: python tools/pixel_layout_audit.py
只读图片, 不写任何文件。
"""
import os
from PIL import Image

DIR = "J:/xiangm_transfer/xiangm/back/clean_manhua_flutter/test/preview"

# 真实模拟器截图（MuMu 1920x1080）与离屏渲染图（Flutter test golden）
TARGETS = [
    "mumu_home_final.png",
    "mumu_bookshelf.png",
    "mumu_tools.png",
    "mumu_profile.png",
    "main_390.png",
    "main_1024.png",
    "main_1440.png",
]


def q3(c, step=10):
    """色重量化，用于统计背景主色。"""
    return (c[0] // step, c[1] // step, c[2] // step)


def measure(path, sample_w=480):
    im = Image.open(path).convert("RGB")
    ow, oh = im.size
    scale = float(sample_w) / ow
    sample_h = max(1, int(round(oh * scale)))
    small = im.resize((sample_w, sample_h))
    px = small.load()
    w, h = small.size

    hist = {}
    for y in range(h):
        for x in range(w):
            k = q3(px[x, y])
            hist[k] = hist.get(k, 0) + 1
    bg_key = max(hist, key=hist.get)
    bg = (bg_key[0] * 10 + 5, bg_key[1] * 10 + 5, bg_key[2] * 10 + 5)
    bg_ratio = float(hist[bg_key]) / (w * h)

    row_hit = [0] * h
    col_hit = [0] * w
    fg = 0
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            d = abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2])
            if d > 42:
                row_hit[y] += 1
                col_hit[x] += 1
                fg += 1

    def bands(hits, total, lo, hi):
        """按行/列命中占比切带，返回 [(起点, 终点, 是否内容)]。"""
        out = []
        cur = None
        for i, n in enumerate(hits):
            frac = float(n) / total if total else 0.0
            is_content = frac >= lo and frac <= hi
            if cur is None:
                cur = [i, i + 1, is_content]
            elif cur[2] == is_content:
                cur[1] = i + 1
            else:
                out.append(tuple(cur))
                cur = [i, i + 1, is_content]
        if cur is not None:
            out.append(tuple(cur))
        return out

    rb = bands(row_hit, w, 0.004, 1.0)
    content_bands = [b for b in rb if b[2] and (b[1] - b[0]) >= 3]
    blank_bands = [b for b in rb if not b[2] and (b[1] - b[0]) >= 6]
    blank_bands.sort(key= lambda b: -(b[1] - b[0]))

    used_rows = [i for i, n in enumerate(row_hit) if n > w * 0.004]
    used_cols = [i for i, n in enumerate(col_hit) if n > h * 0.004]
    top = used_rows[0] if used_rows else 0
    bot = used_rows[-1] if used_rows else h - 1
    left = used_cols[0] if used_cols else 0
    right = used_cols[-1] if used_cols else w - 1

    print("=" * 78)
    print("%s   (%dx%d px, 采样 %dx%d)" % (os.path.basename(path), ow, oh, w, h))
    print("  背景主色 rgb%s  占屏 %.1f%%   信息密度(非背景像素) %.1f%%"
          % (bg, bg_ratio * 100, float(fg) / (w * h) * 100))
    print("  内容纵向跨度 %.1f%%–%.1f%% 屏幕高（即顶部空 %.1f%%、底部空 %.1f%%）"
          % (top * 100.0 / h, bot * 100.0 / h, top * 100.0 / h, (h - 1 - bot) * 100.0 / h))
    print("  内容横向跨度 %.1f%%–%.1f%% 屏幕宽（左留白 %.1f%%、右留白 %.1f%%）"
          % (left * 100.0 / w, right * 100.0 / w,
             left * 100.0 / w, (w - 1 - right) * 100.0 / w))
    print("  内容带数量 %d 个（≥3 行才算一屏内区块）" % len(content_bands))
    print("  最空 3 段空白（原图像素，占屏高）：")
    for b in blank_bands[:3]:
        print("     y %4d–%4d  高 %3dpx  = 屏高 %.1f%%"
              % (b[0] / scale, b[1] / scale, (b[1] - b[0]) / scale,
                 (b[1] - b[0]) * 100.0 / h))


def main():
    for name in TARGETS:
        p = os.path.join(DIR, name)
        if os.path.exists(p):
            measure(p)
        else:
            print("缺失: " + name)


main()
