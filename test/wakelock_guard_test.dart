import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/utils/wakelock_guard.dart';

/// P1-25 屏幕常亮引用计数的回归。
///
/// 背景：移除全局常亮后，常亮由页面各自持有。而「动漫播放页 → 原生播放器」
/// 是 pushReplacement，新页 initState 与旧页 dispose 的**先后顺序不由我们
/// 决定**——若各页面直接 enable/disable，后跑的 dispose 会把新页刚拿到的
/// 常亮关掉。引用计数必须保证「最后一个持有者退出才释放」。
void main() {
  final guard = WakelockGuard.instance;

  setUp(guard.releaseAll);

  group('引用计数语义', () {
    test('单页面 acquire/release 对称', () {
      guard.acquire();
      expect(guard.refs, 1);
      expect(guard.holding, isTrue);
      guard.release();
      expect(guard.refs, 0);
      expect(guard.holding, isFalse);
    });

    test('两个页面叠持：只在前一个退出后仍保持常亮', () {
      guard.acquire(); // A 页
      guard.acquire(); // B 页（pushReplacement 的新页）
      expect(guard.refs, 2);
      guard.release(); // A 页 dispose（可能晚于 B 页 initState）
      expect(guard.refs, 1);
      expect(guard.holding, isTrue,
          reason: 'B 页仍在播放，常亮不能被 A 页的 dispose 关掉');
      guard.release(); // B 页 dispose
      expect(guard.holding, isFalse);
    });

    test('交错顺序（先 init 新页、后 dispose 旧页）不丢常亮', () {
      // 这正是 pushReplacement 的真实时序：B.initState() 先跑，
      // A.dispose() 后跑。若用裸 enable/disable，A 的 disable 会误关。
      guard.acquire(); // A
      guard.acquire(); // B
      guard.release(); // A dispose
      guard.release(); // B dispose
      expect(guard.holding, isFalse);
      // 再来一轮：B 先 init、A 后 dispose
      guard.acquire(); // A
      guard.acquire(); // B
      guard.release(); // A
      expect(guard.holding, isTrue);
      guard.release(); // B
      expect(guard.holding, isFalse);
    });

    test('release 多于 acquire 被夹紧到 0，不变负', () {
      guard.acquire();
      guard.release();
      guard.release(); // 多余调用
      guard.release();
      expect(guard.refs, 0);
      // 夹紧之后计数仍能正常工作。
      guard.acquire();
      expect(guard.refs, 1);
      guard.release();
      expect(guard.refs, 0);
    });

    test('零持有时 release 是 no-op', () {
      expect(guard.refs, 0);
      guard.release();
      expect(guard.refs, 0);
      expect(guard.holding, isFalse);
    });

    test('releaseAll 一次性清空', () {
      guard.acquire();
      guard.acquire();
      guard.acquire();
      guard.releaseAll();
      expect(guard.refs, 0);
      expect(guard.holding, isFalse);
    });

    test('同一页面重复 acquire 会正确计数（防止持锁丢失）', () {
      guard.acquire();
      guard.acquire(); // 同一页意外两次 acquire（防御性）
      expect(guard.refs, 2);
      guard.release();
      expect(guard.holding, isTrue,
          reason: '两次 acquire 只 release 一次时仍应保持常亮');
      guard.release();
      expect(guard.holding, isFalse);
    });
  });
}
