"""四页面 UI 设计一致性静态审计（只读不改）。

输出：字号/圆角/alpha 使用分布与离散度、EdgeInsets 字面量、Colors.* 直用统计。
运行：python tools/ui_audit.py
"""
import collections
import os
import re

BASE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(BASE)

FILES = [
    'lib/ui/home_page.dart',
    'lib/ui/anime_home_page.dart',
    'lib/ui/novel_home_page.dart',
    'lib/ui/bookshelf_page.dart',
    'lib/ui/toolbox_page.dart',
    'lib/ui/profile_page.dart',
    'lib/ui/main_shell.dart',
    'lib/ui/detail_page.dart',
    'lib/ui/responsive.dart',
    'lib/theme.dart',
]

FONT = re.compile(r'fontSize\s*:\s*([0-9][0-9.]*)')
RAD = re.compile(r'Border\.circular\(\s*([0-9][0-9.]*)')
ALPHA = re.compile(r'alpha\s*:\s*([0-9][0-9.]*)')
COLORS = re.compile(r'Colors\.([a-z_]+)')
PAD = re.compile(r'EdgeInsets\.[a-z]+\([^)]*\)')
LITERAL_PX = re.compile(r'(?:height|width|vertical|horizontal|blurRadius|size)\s*:\s*([0-9][0-9.]*)')


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


def main():
    agg_font = collections.Counter()
    agg_rad = collections.Counter()
    agg_alpha = collections.Counter()
    agg_px = collections.Counter()
    print('%-28s %5s %6s %6s %6s %6s %7s %7s %6s' %
          ('file', 'lines', 'fontN', 'fontK', 'radN', 'radK', 'alphaN', 'colors', 'pad'))
    for rel in FILES:
        p = os.path.join(PROJ, rel.replace('/', os.sep))
        if not os.path.exists(p):
            print('%-28s MISSING' % rel)
            continue
        s = read(p)
        lines = s.count('\n') + 1
        fonts = [float(x) for x in FONT.findall(s)]
        rads = [float(x) for x in RAD.findall(s)]
        alphas = [float(x) for x in ALPHA.findall(s)]
        colors = COLORS.findall(s)
        pads = PAD.findall(s)
        px = [float(x) for x in LITERAL_PX.findall(s)]
        agg_font.update(fonts)
        agg_rad.update(rads)
        agg_alpha.update(alphas)
        agg_px.update(px)
        print('%-28s %5d %6d %6d %6d %6d %7d %7d %6d' % (
            rel, lines, len(fonts), len(set(fonts)), len(rads), len(set(rads)),
            len(alphas), len(colors), len(pads)))

    for title, agg, unit in (('字号', agg_font, 'px'), ('圆角', agg_rad, 'r'),
                             ('透明度', agg_alpha, 'a')):
        print()
        print('=== 全项目 %s 使用分布 ===' % title)
        for v, c in sorted(agg.items(), key=lambda kv: (-kv[1], kv[0])):
            print('  %-6s x%-4d' % (v, c))
        print('  合计 %d 处 / %d 种不同取值' % (sum(agg.values()), len(agg)))

    print()
    print('=== 尺寸字面量（height/width/vertical/horizontal/blurRadius/size）TOP30 ===')
    for v, c in sorted(agg_px.items(), key=lambda kv: (-kv[1], kv[0]))[:30]:
        print('  %-6s x%-4d' % (v, c))
    print('  合计 %d 处 / %d 种不同取值' % (sum(agg_px.values()), len(agg_px)))


main()
