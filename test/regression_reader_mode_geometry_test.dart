import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/reader_mode_geometry.dart';

/// 双页阅读几何换算回归：
/// 封面单独占页（≥3 页时第 0 页独占 view 0，从页 1 起两两并排），
/// 单页/纵向退化为恒等，末组单页由 ColoredBox 占位（不强制拼接）。
void main() {
  group('viewCountOf（双页视图数）', () {
    test('单页/纵向 = 页数（恒等）', () {
      expect(viewCountOf(5, ReaderMode.vertical), 5);
      expect(viewCountOf(5, ReaderMode.single), 5);
      expect(viewCountOf(0, ReaderMode.single), 0);
    });

    test('双页 <3 页不触发封面占页：1 页=1 视图、2 页=1 视图', () {
      expect(viewCountOf(1, ReaderMode.double), 1);
      expect(viewCountOf(2, ReaderMode.double), 1);
    });

    test('双页 ≥3 页 = 1（封面）+ ceil((n-1)/2)', () {
      expect(viewCountOf(3, ReaderMode.double), 2); // 封面 + [1,2]
      expect(viewCountOf(4, ReaderMode.double), 3); // 封面 + [1,2][3,占位]
      expect(viewCountOf(5, ReaderMode.double), 3); // 封面 + [1,2][3,4]
      expect(viewCountOf(6, ReaderMode.double), 4); // 封面 + [1,2][3,4][5,6]
    });
  });

  group('pageOfView（视图 -> 起始页/lead）', () {
    test('单页/纵向恒等', () {
      expect(pageOfView(3, ReaderMode.single), 3);
      expect(pageOfView(3, ReaderMode.vertical), 3);
    });

    test('双页：view 0 -> 页 0（封面），view>0 -> 1+(view-1)*2', () {
      expect(pageOfView(0, ReaderMode.double), 0);
      expect(pageOfView(1, ReaderMode.double), 1);
      expect(pageOfView(2, ReaderMode.double), 3);
      expect(pageOfView(3, ReaderMode.double), 5);
    });
  });

  group('viewOfPage（页 -> 所在视图）', () {
    test('单页/纵向恒等', () {
      expect(viewOfPage(3, ReaderMode.single), 3);
      expect(viewOfPage(3, ReaderMode.vertical), 3);
    });

    test('双页：页 0 -> view 0（封面），页>0 -> 1+(p-1)~/2', () {
      expect(viewOfPage(0, ReaderMode.double), 0);
      expect(viewOfPage(1, ReaderMode.double), 1);
      expect(viewOfPage(2, ReaderMode.double), 1);
      expect(viewOfPage(3, ReaderMode.double), 2);
      expect(viewOfPage(4, ReaderMode.double), 2);
      expect(viewOfPage(5, ReaderMode.double), 3);
    });
  });

  group('往返与覆盖', () {
    test('viewOfPage(pageOfView(v)) == v（所有有效视图）', () {
      for (var n = 3; n <= 10; n++) {
        final views = viewCountOf(n, ReaderMode.double);
        for (var v = 0; v < views; v++) {
          expect(
            viewOfPage(pageOfView(v, ReaderMode.double), ReaderMode.double),
            v,
            reason: 'n=$n 视图 $v 往返映射应回到自身',
          );
        }
      }
    });

    test('双页视图覆盖全部页且每视图 ≤2 页', () {
      for (var n = 3; n <= 10; n++) {
        final views = viewCountOf(n, ReaderMode.double);
        final covered = <int>[];
        for (var v = 0; v < views; v++) {
          final lead = pageOfView(v, ReaderMode.double);
          if (v == 0) {
            // 封面单独占页：只覆盖页 0
            covered.add(lead);
          } else {
            if (lead < n) covered.add(lead);
            if (lead + 1 < n) covered.add(lead + 1);
          }
        }
        // 封面占页：每页恰被覆盖一次（并排视图 lead/lead+1 无重复）
        expect(covered.length, n, reason: 'n=$n 全部页应被覆盖');
        expect(covered.toSet().length, n, reason: 'n=$n 无重复覆盖');
      }
    });
  });
}
