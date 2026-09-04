"""把截图降采样成 ASCII 明度图，让无视觉能力的模型也能读到真实版面结构。

块平均亮度映射到字符梯度；高饱和（彩色）块标 C；亮度分 10 级。
用法: python tools/ascii_view.py <png 路径> [列数=76]
"""
import os
import sys
from PIL import Image

RAMPS = " .:-+=*#%@"


def art(path, cols=76):
    im = Image.open(path).convert("RGB") if False else Image.open(path).convert("RGB")
    return _render(im, cols)


def _render(im, cols):
    ow, oh = im.size
    rows = max(1, int(cols * oh / ow * 0.5))
    small = im.resize((cols, rows))
    px = small.load()
    out = []
    for y in range(rows):
        line = []
        for x in range(cols):
            r, g, b = px[x, y]
            lum = 0.299 * r + 0.587 * g + 0.114 * b
            mx = max(r, g, b)
            mn = min(r, g, b)
            sat = 0.0 if mx == 0 else (mx - mn) / float(mx)
            if sat > 0.35:
                line.append("C")
            else:
                idx = int(lum / 256.0 * len(RAMPS))
                idx = min(len(RAMPS) - 1, max(0, idx))
                line.append(RAMPS[idx])
        y0 = int(y * oh / float(rows))
        y1 = int((y + 1) * oh / float(rows))
        out.append("%2d y%4d-%4d|%s" % (y, y0, y1, "".join(line)))
    return "%dx%d px -> %dx%d 梯度[空格=最亮 -> @=最暗, C=彩色]\n%s" % (
        ow, oh, cols, rows, "\n".join(out))


def main():
    args = [a for a in sys.argv[1:]] if False else sys.argv[1:]
    if not args:
        print(__doc__)
        return
    cols = 76
    path = args[0]
    if len(args) > 1:
        cols = int(args[1])
    print(art(path, cols))


main()
