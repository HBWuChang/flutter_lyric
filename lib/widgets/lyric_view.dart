import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_controller.dart';
import 'package:flutter_lyric/render/lyric_painter.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_line_highlight.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_line_switch_mixin.dart';

import '../core/lyric_style.dart';
import '../core/lyric_styles.dart';
import '../render/lyric_layout.dart';
import 'mixins/lyric_layout_mixin.dart';
import 'mixins/lyric_mask_mixin.dart';
import 'mixins/lyric_scroll_mixin.dart';
import 'mixins/lyric_touch_mixin.dart';

class LyricView extends StatefulWidget {
  final LyricController controller;
  final double? width;
  final double? height;
  final LyricStyle? style;
  const LyricView({
    Key? key,
    required this.controller,
    this.width,
    this.height,
    this.style,
  }) : super(key: key);

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView>
    with
        TickerProviderStateMixin,
        LyricLayoutMixin,
        LyricScrollMixin,
        LyricMaskMixin,
        LyricTouchMixin,
        LyricLineHightlightMixin,
        LyricLineSwitchMixin {
  // 提供 mixin 需要的属性访问
  @override
  LyricController get controller => widget.controller;

  @override
  LyricStyle get style => widget.style ?? LyricStyles.default1;
  // 布局相关状态
  @override
  LyricLayout? layout;

  @override
  Size lyricSize = Size.zero;

  // 动画相关状态
  @override
  final scrollYNotifier = ValueNotifier<double>(0.0);

  @override
  void onLayoutChange(LyricLayout layout) {
    super.onLayoutChange(layout);
    updateHighlightWidth();
    updateScrollY(animate: false);
  }

  @override
  void didUpdateWidget(covariant LyricView oldWidget) {
    if (widget.style != oldWidget.style) {
      onStyleChange();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    return wrapTouchWidget(
      context,
      SizedBox(
        width: widget.width ?? double.infinity,
        height: widget.height ?? double.infinity,
        child: Padding(
          padding: style.contentPadding.copyWith(top: 0, bottom: 0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              if (size.width != lyricSize.width ||
                  size.height != lyricSize.height) {
                lyricSize = size;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  computeLyricLayout();
                });
              }
              if (layout == null) return const SizedBox.shrink();
              // 文字层与高亮层分离：
              // - 文字层只在滚动 / 切行 / 选中变化时重绘；
              // - 高亮层随播放进度逐帧重绘，但只绘制当前行的高亮。
              // 两层各自包在 RepaintBoundary 中，避免互相触发重绘；
              // 上下渐隐由 painter 在内部离屏图层里用 dstOut 实现。
              return buildLineSwitch((context, switchState) {
                return Stack(
                  clipBehavior: Clip.none,
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: ValueListenableBuilder<double>(
                        valueListenable: scrollYNotifier,
                        builder: (context, scrollY, child) {
                          return CustomPaint(
                            painter: LyricPainter(
                              layout: layout!,
                              playIndex: controller.activeIndexNotifiter.value,
                              isSelecting:
                                  controller.isSelectingNotifier.value,
                              scrollY: scrollY,
                              switchState: switchState,
                              onShowLineRectsChange: (rects) {
                                showLineRects = rects;
                              },
                              onAnchorIndexChange: (index) {
                                scheduleMicrotask(() {
                                  controller.selectedIndexNotifier.value =
                                      index;
                                });
                              },
                              style: style,
                            ),
                            size: lyricSize,
                          );
                        },
                      ),
                    ),
                    RepaintBoundary(
                      child: buildActiveHighlightWidth((value) {
                        return ValueListenableBuilder<double>(
                          valueListenable: scrollYNotifier,
                          builder: (context, scrollY, child) {
                            return CustomPaint(
                              painter: LyricHighlightPainter(
                                layout: layout!,
                                playIndex:
                                    controller.activeIndexNotifiter.value,
                                scrollY: scrollY,
                                switchState: switchState,
                                style: style,
                                activeHighlightWidth: value,
                              ),
                              size: lyricSize,
                            );
                          },
                        );
                      }),
                    ),
                  ],
                );
              });
            },
          ),
        ),
      ),
    );
  }
}
