import 'package:flutter/material.dart';

import '../responsive.dart';

/// 顶部圆返回按钮（P1-22：detail_page / episode_list_page 双份合一）。
///
/// 语义与两处原私有实现一致：点击 [Navigator.maybePop]。平板分栏场景
/// 用浅色底（跟随主题），手机端用深色半透明底 + 白图标（压在 Hero 图上）。
/// [size] 默认 40（与 detail 原版一致）；episode 列表原版 36，调用处可收窄。
class BackCircleButton extends StatelessWidget {
  final double size;
  const BackCircleButton({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isTablet = Responsive.isTablet(context);

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Material(
        color: isTablet
            ? scheme.surface.withValues(alpha: 0.9)
            : Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => Navigator.maybePop(context),
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              Icons.arrow_back_rounded,
              color: isTablet ? scheme.onSurface : Colors.white,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
