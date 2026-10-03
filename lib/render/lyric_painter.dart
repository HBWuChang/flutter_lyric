import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_model.dart';
import 'package:flutter_lyric/core/lyric_style.dart';
import 'package:flutter_lyric/render/lyric_layout.dart';
import 'package:flutter_lyric/widgets/mixins/lyric_line_switch_mixin.dart';

const _debugLyric = false;

class _HighlightSegment {
  final Rect rect;
  final ui.Shader shader;

  _HighlightSegment(this.rect, this.shader);
}

/// 顶部/底部渐隐带（屏幕坐标）。
class _FadeBand {
  final Rect rect;
  final Gradient gradient;

  const _FadeBand(this.rect, this.gradient);
}

/// 歌词绘制基类：集中处理布局、行切换动画、边缘渐变遮罩等公共逻辑。
///
/// 绘制被拆成两层（见 [LyricPainter] 与 [LyricHighlightPainter]）：
/// 播放时每帧变化的逐字高亮只重绘高亮层，不再连带整屏文字一起重绘。
abstract class _LyricPainterBase extends CustomPainter {
  final LyricLayout layout;
  final int playIndex;
  final double scrollY;
  final LyricLineSwitchState switchState;
  final LyricStyle style;

  _LyricPainterBase({
    required this.layout,
    required this.playIndex,
    required this.scrollY,
    required this.switchState,
    required this.style,
  });

  /// 第 [index] 行顶部的 Y 坐标（与 [LyricPainter.paint] 中逐行累加逻辑一致）。
  double lineTopY(int index) {
    final metrics = layout.metrics;
    var y = -scrollY;
    for (var i = 0; i < index && i < metrics.length; i++) {
      y += layout.getLineHeight(i == playIndex, i) + layout.style.lineGap;
    }
    return y;
  }

  /// 是否启用上下渐隐。
  bool get hasEdgeFade {
    final fadeRange = style.fadeRange;
    return fadeRange != null && (fadeRange.top > 0 || fadeRange.bottom > 0);
  }

  /// 顶部/底部渐隐带（屏幕坐标）。
  List<_FadeBand> edgeFadeBands(Size size) {
    final fadeRange = style.fadeRange;
    if (fadeRange == null) return const [];
    var top = fadeRange.top;
    var bottom = fadeRange.bottom;
    if (top <= 0 && bottom <= 0) return const [];
    if (top > 1) top = top / size.height;
    if (bottom > 1) bottom = bottom / size.height;
    top = top.clamp(0.0, 1.0);
    bottom = bottom.clamp(0.0, 1.0);
    final bands = <_FadeBand>[];
    if (top > 0) {
      final rect = Rect.fromLTWH(0, 0, size.width, size.height * top);
      bands.add(_FadeBand(
        rect,
        const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black, Colors.transparent],
        ),
      ));
    }
    if (bottom > 0) {
      final rect = Rect.fromLTWH(
          0, size.height * (1 - bottom), size.width, size.height * bottom);
      bands.add(_FadeBand(
        rect,
        const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ),
      ));
    }
    return bands;
  }

  /// [rect]（屏幕坐标）是否与渐隐带相交。
  bool intersectsEdgeFade(Rect rect, Size size) {
    for (final band in edgeFadeBands(size)) {
      if (band.rect.overlaps(rect)) return true;
    }
    return false;
  }

  /// 只对顶部/底部渐变区域做 dstOut 遮罩，替代整屏 ShaderMask 的 saveLayer。
  ///
  /// 必须在“屏幕坐标”下、且在真实的离屏图层内调用：
  /// - 屏幕坐标：调用前先 restore 掉内容绘制时的 translate，否则渐变会落到错误位置；
  /// - 离屏图层：dstOut 会擦除目标图层内容，仅靠 RepaintBoundary 不够（它只是
  ///   重绘边界，不会创建离屏层），否则会擦到下层背景形成灰色渐变带。
  void paintEdgeFade(Canvas canvas, Size size) {
    final bands = edgeFadeBands(size);
    if (bands.isEmpty) return;
    final paint = Paint()..blendMode = BlendMode.dstOut;
    for (final band in bands) {
      paint.shader = band.gradient.createShader(band.rect);
      canvas.drawRect(band.rect, paint);
    }
  }

  void drawHighlight(
    Canvas canvas,
    Size size,
    TextPainter maskPainter,
    List<ui.LineMetrics> metrics, {
    double highlightTotalWidth = 0,
    double animationOpacity = 1.0,
  }) {
    if (highlightTotalWidth < 0 || animationOpacity <= 0) return;
    final activeHighlightColor = layout.style.activeHighlightColor;
    final activeHighlightGradient = layout.style.activeHighlightGradient;
    if (activeHighlightColor == null && activeHighlightGradient == null) {
      return;
    }

    final highlightFullMode = highlightTotalWidth == double.infinity;
    var accWidth = 0.0;

    final grad = activeHighlightGradient ??
        LinearGradient(colors: [activeHighlightColor!, activeHighlightColor]);

    final opColors = animationOpacity < 1.0
        ? grad.colors
            .map((c) =>
                c.withValues(alpha: (c.a * animationOpacity).clamp(0.0, 1.0)))
            .toList()
        : grad.colors;

    final extraFadeWidth = style.activeHighlightExtraFadeWidth;
    final fadeEndColor = opColors.last.withValues(alpha: 0);

    const pad = 2;
    final segments = <_HighlightSegment>[];
    Rect? layerBounds;

    void addSegment(Rect rect, ui.Shader shader) {
      segments.add(_HighlightSegment(rect, shader));
      layerBounds =
          layerBounds == null ? rect : layerBounds!.expandToInclude(rect);
    }

    for (var line in metrics) {
      if (highlightFullMode) {
        final rect = Rect.fromLTWH(
          line.left - pad,
          line.baseline - line.ascent,
          line.width + pad,
          line.ascent + line.descent,
        );
        addSegment(
          rect,
          LinearGradient(
            colors: opColors,
            stops: grad.stops,
            begin: grad.begin,
            end: grad.end,
            tileMode: grad.tileMode,
            transform: grad.transform,
          ).createShader(rect),
        );
        accWidth += line.width;
        continue;
      }

      final fadeEnd = highlightTotalWidth - accWidth;
      if (fadeEnd <= 0) break;

      final top = line.baseline - line.ascent;
      final height = line.ascent + line.descent;
      final fadeWidth = extraFadeWidth > 0 ? extraFadeWidth : 0.0;
      final fadeStart = fadeEnd - fadeWidth;
      final solidEnd = fadeWidth > 0 ? fadeStart : fadeEnd;

      if (solidEnd > 0) {
        final solidRect = Rect.fromLTRB(
          line.left - pad,
          top,
          line.left + solidEnd.clamp(0.0, line.width),
          top + height,
        );
        addSegment(
          solidRect,
          LinearGradient(
            colors: opColors,
            stops: grad.stops,
            begin: grad.begin,
            end: grad.end,
            tileMode: grad.tileMode,
            transform: grad.transform,
          ).createShader(solidRect),
        );
      }

      if (fadeWidth > 0 && fadeStart < line.width) {
        final fadeRect = Rect.fromLTRB(
          line.left + fadeStart,
          top,
          line.left + fadeEnd,
          top + height,
        );
        addSegment(
          fadeRect,
          LinearGradient(colors: [opColors.last, fadeEndColor])
              .createShader(fadeRect),
        );
      }

      accWidth += line.width;

      if (highlightTotalWidth <= accWidth) break;
    }

    if (segments.isNotEmpty && layerBounds != null) {
      _drawMaskedHighlightSegments(
        canvas,
        maskPainter,
        layerBounds!,
        segments,
      );
    }
  }

  void _drawMaskedHighlightSegments(
    Canvas canvas,
    TextPainter maskPainter,
    Rect bounds,
    List<_HighlightSegment> segments,
  ) {
    canvas.save();
    canvas.clipRect(bounds);
    canvas.saveLayer(bounds, Paint());
    final paint = Paint();
    for (final segment in segments) {
      paint.shader = segment.shader;
      canvas.drawRect(segment.rect, paint);
    }
    canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.dstIn);
    maskPainter.paint(canvas, Offset.zero);
    canvas.restore();
    canvas.restore();
    canvas.restore();
  }

  double handleSwitchAnimation(
    Canvas canvas,
    LineMetrics metric,
    int index,
    LyricLineSwitchState switchState,
    TextPainter painter,
    Size size,
  ) {
    if (layout.style.enableSwitchAnimation != true) return 0;
    double calcTranslateX(double contentWidth) {
      var transX = 0.0;
      if (layout.style.contentAlignment == CrossAxisAlignment.center) {
        transX = contentWidth / 2;
      } else if (layout.style.contentAlignment == CrossAxisAlignment.end) {
        transX = contentWidth;
      }
      return transX;
    }

    final transX = calcTranslateX(painter.width);
    if (index == switchState.enterIndex) {
      final enterAnimationValue = switchState.enterAnimationValue;
      final fromHeight = metric.height;
      final toHeight = metric.activeHeight;
      final transY = toHeight;
      canvas.translate(transX, transY);
      canvas.scale(
          1 - ((toHeight - fromHeight) / toHeight) * (1 - enterAnimationValue));
      canvas.translate(-transX, -transY);
    }
    // EXIT
    if (index == switchState.exitIndex) {
      final exitAnimationValue = switchState.exitAnimationValue;
      final fromHeight = metric.activeHeight;
      final toHeight = metric.height;
      final transY = 0.0;
      canvas.translate(transX, transY);
      final scale =
          ((fromHeight - toHeight) / fromHeight) * (1 - exitAnimationValue);
      canvas.scale(1 + scale);
      canvas.translate(-transX, -transY);
      return toHeight * scale;
    }
    return 0;
  }

  double calcContentAliginOffset(double contentWidth, double containerWidth) {
    switch (layout.style.contentAlignment) {
      case CrossAxisAlignment.start:
        return 0;
      case CrossAxisAlignment.end:
        return containerWidth - contentWidth;
      case CrossAxisAlignment.center:
        return (containerWidth - contentWidth) / 2;
      default:
        return 0;
    }
  }

  bool shouldRepaintCommon(covariant _LyricPainterBase oldDelegate) {
    return layout != oldDelegate.layout ||
        playIndex != oldDelegate.playIndex ||
        scrollY != oldDelegate.scrollY ||
        switchState != oldDelegate.switchState;
  }
}

/// 歌词文字层：绘制普通文字、翻译与行切换动画，不绘制逐字高亮。
///
/// 只在滚动 / 切行 / 选中状态变化时重绘，播放进度不会触发这一层。
class LyricPainter extends _LyricPainterBase {
  final bool isSelecting;
  final void Function(int) onAnchorIndexChange;
  final void Function(Map<int, Rect>) onShowLineRectsChange;

  LyricPainter({
    required LyricLayout layout,
    required int playIndex,
    required double scrollY,
    required LyricLineSwitchState switchState,
    required this.isSelecting,
    required this.onAnchorIndexChange,
    required this.onShowLineRectsChange,
    required LyricStyle style,
  }) : super(
          layout: layout,
          playIndex: playIndex,
          scrollY: scrollY,
          switchState: switchState,
          style: style,
        );

  @override
  void paint(Canvas canvas, Size size) {
    final layoutStyle = layout.style;
    final lineGap = layoutStyle.lineGap;
    final metrics = layout.metrics;

    // 上下渐隐依赖 dstOut 擦除，必须在离屏图层内进行，否则会擦到下层背景；
    // 仅在启用渐隐时创建。文字层只在滚动 / 切行时重绘，
    // 播放中的逐字高亮不会触发这里的 saveLayer。
    final needsFadeLayer = hasEdgeFade;
    if (!_debugLyric) {
      canvas.clipRect(Rect.fromLTRB(-layoutStyle.contentPadding.left, 0,
          size.width + layoutStyle.contentPadding.right, size.height));
    }
    if (needsFadeLayer) {
      canvas.saveLayer(Offset.zero & size, Paint());
    }
    // 内容在带位移的画布上绘制，restore 后回到屏幕坐标再做渐隐，
    // 避免 dstOut 渐变被内容位移影响而擦到错误位置。
    canvas.save();

    final selectionPosition = layout.selectionAnchorPosition;
    if (_debugLyric) {
      final activePosition = layout.activeAnchorPosition;
      final debugPaint = Paint()..color = layoutStyle.selectedColor;
      canvas.drawLine(
        Offset(0, selectionPosition),
        Offset(size.width, selectionPosition),
        debugPaint,
      );
      canvas.drawLine(
        Offset(0, activePosition),
        Offset(size.width, activePosition),
        debugPaint,
      );
    }
    var totalTranslateY = -scrollY;
    canvas.translate(0, -scrollY);
    var selectedIndex = -1;
    final showLineRects = <int, Rect>{};
    final halfLineGap = lineGap / 2;
    final contentHorizontal = layoutStyle.contentPadding.horizontal;
    final activeLineOnly = style.activeLineOnly;

    for (var i = 0; i < metrics.length; i++) {
      final isActive = i == playIndex;
      final lineHeight = layout.getLineHeight(isActive, i);
      totalTranslateY += lineHeight;
      if ((totalTranslateY + halfLineGap) >= selectionPosition &&
          selectedIndex == -1) {
        selectedIndex = i;
        onAnchorIndexChange(i);
      }
      if (totalTranslateY - lineHeight >= size.height) {
        break;
      }
      if (totalTranslateY > 0) {
        showLineRects[i] = Rect.fromLTWH(0, totalTranslateY - lineHeight,
            size.width + contentHorizontal, lineHeight);
        if (!activeLineOnly || isActive) {
          drawLine(canvas, metrics[i], size, i, selectedIndex == i);
        }
      }
      totalTranslateY += lineGap;
      if (_debugLyric) {
        canvas.drawRect(Rect.fromLTWH(0, 0, size.width, lineHeight),
            Paint()..color = Colors.purple.withAlpha(50));
      }
      canvas.translate(0, lineHeight + lineGap);
    }
    onShowLineRectsChange(showLineRects);
    canvas.restore();
    paintEdgeFade(canvas, size);
    if (needsFadeLayer) {
      canvas.restore();
    }
  }

  Color _resolveColor(TextStyle baseStyle, Color selectColor, bool isSelecting,
      bool isInAnchorArea, Color? customColor) {
    if (isSelecting && isInAnchorArea) return selectColor;
    return customColor ?? baseStyle.color!;
  }

  void drawLine(
    Canvas canvas,
    LineMetrics metric,
    Size size,
    int index,
    bool isInAnchorArea,
  ) {
    final isActive = playIndex == index;
    final layoutStyle = layout.style;

    final painter = isActive ? metric.activeTextPainter : metric.textPainter;
    final oldSpan = painter.text! as TextSpan;

    Color? animatedMainColor;
    if (style.enableSwitchAnimation) {
      final normalColor = layoutStyle.textStyle.color;
      final activeColor = layoutStyle.activeStyle.color;

      if (index == switchState.enterIndex) {
        animatedMainColor = Color.lerp(
            normalColor, activeColor, switchState.enterAnimationValue);
      } else if (index == switchState.exitIndex) {
        animatedMainColor = Color.lerp(
            activeColor, normalColor, switchState.exitAnimationValue);
      }
    }

    final targetColor = _resolveColor(oldSpan.style!, layoutStyle.selectedColor,
        isSelecting, isInAnchorArea, animatedMainColor);
    final needsRestyle = targetColor != oldSpan.style!.color;

    if (needsRestyle) {
      painter.text = TextSpan(
        text: oldSpan.text,
        style: oldSpan.style!.copyWith(color: targetColor),
      );
    }
    canvas.save();
    canvas.translate(calcContentAliginOffset(painter.width, size.width), 0);
    if (_debugLyric) {
      canvas.drawRect(
          Rect.fromLTWH(0, 0, painter.width, painter.height),
          Paint()
            ..color = !isActive
                ? Colors.blue.withAlpha(50)
                : Colors.red.withAlpha(50));
    }
    final switchOffset = handleSwitchAnimation(
        canvas, metric, index, switchState, painter, size);
    painter.paint(canvas, Offset.zero);
    if (needsRestyle) {
      painter.text = oldSpan;
    }
    canvas.restore();
    final mainHeight = isActive ? metric.activeHeight : metric.height;
    if (metric.line.translation?.isNotEmpty == true) {
      final tPainter = metric.translationTextPainter;
      final tOldSpan = tPainter.text! as TextSpan;

      Color? animatedTranslationColor;
      if (style.enableSwitchAnimation) {
        final normalTransColor =
            tOldSpan.style!.color ?? layoutStyle.translationStyle.color;
        final activeTransColor =
            layoutStyle.translationActiveColor ?? normalTransColor;

        if (index == switchState.enterIndex) {
          animatedTranslationColor = Color.lerp(normalTransColor,
              activeTransColor, switchState.enterAnimationValue);
        } else if (index == switchState.exitIndex) {
          animatedTranslationColor = Color.lerp(activeTransColor,
              normalTransColor, switchState.exitAnimationValue);
        }
      }

      final tBaseColor = isActive
          ? (layoutStyle.translationActiveColor ?? tOldSpan.style!.color)
          : tOldSpan.style!.color;
      final tTargetColor = _resolveColor(
          tOldSpan.style!.copyWith(color: tBaseColor),
          layoutStyle.selectedTranslationColor,
          isSelecting,
          isInAnchorArea,
          animatedTranslationColor);
      final tNeedsRestyle = tTargetColor != tOldSpan.style!.color;

      if (tNeedsRestyle) {
        tPainter.text = TextSpan(
          text: tOldSpan.text,
          style: tOldSpan.style!.copyWith(color: tTargetColor),
        );
      }
      canvas.save();
      canvas.translate(calcContentAliginOffset(tPainter.width, size.width), 0);
      canvas.translate(0, switchOffset);
      try {
        tPainter.paint(
          canvas,
          Offset(0, mainHeight + layoutStyle.translationLineGap),
        );
      } catch (_) {
        // 避免系统字体变更触发 assert(debugSize == size);
      }
      if (tNeedsRestyle) {
        tPainter.text = tOldSpan;
      }
      canvas.translate(0, -switchOffset);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant LyricPainter oldDelegate) {
    return shouldRepaintCommon(oldDelegate) ||
        isSelecting != oldDelegate.isSelecting;
  }
}

/// 逐字高亮层：只绘制当前播放行（以及退场行）的高亮。
///
/// 播放进度每帧更新只会重绘这一层，配合外层 RepaintBoundary
/// 避免整屏文字与边缘遮罩被反复重绘。
class LyricHighlightPainter extends _LyricPainterBase {
  final double activeHighlightWidth;

  LyricHighlightPainter({
    required LyricLayout layout,
    required int playIndex,
    required double scrollY,
    required LyricLineSwitchState switchState,
    required LyricStyle style,
    required this.activeHighlightWidth,
  }) : super(
          layout: layout,
          playIndex: playIndex,
          scrollY: scrollY,
          switchState: switchState,
          style: style,
        );

  @override
  void paint(Canvas canvas, Size size) {
    final layoutStyle = layout.style;
    final metrics = layout.metrics;

    canvas.clipRect(Rect.fromLTRB(-layoutStyle.contentPadding.left, 0,
        size.width + layoutStyle.contentPadding.right, size.height));

    if (metrics.isNotEmpty) {
      final switchAnimationEnabled = style.enableSwitchAnimation == true;

      // 当前播放行高亮
      if (playIndex >= 0 && playIndex < metrics.length) {
        final metric = metrics[playIndex];
        var highlightOpacity = 1.0;
        if (switchAnimationEnabled) {
          if (playIndex == switchState.enterIndex) {
            highlightOpacity = switchState.enterAnimationValue;
          } else if (playIndex == switchState.exitIndex) {
            highlightOpacity = 1.0 - switchState.exitAnimationValue;
          }
        }
        _paintLineHighlight(
          canvas,
          size,
          index: playIndex,
          metric: metric,
          maskPainter: metric.activeMaskPainter,
          lineMetrics: metric.activeMetrics,
          textPainter: metric.activeTextPainter,
          highlightTotalWidth: metric.words?.isNotEmpty == true
              ? activeHighlightWidth
              : double.infinity,
          animationOpacity: highlightOpacity,
        );
      }

      // 行切换动画期间旧行的退场高亮
      final exitIndex = switchState.exitIndex;
      if (switchAnimationEnabled &&
          exitIndex != playIndex &&
          exitIndex >= 0 &&
          exitIndex < metrics.length &&
          switchState.exitAnimationValue < 1) {
        final metric = metrics[exitIndex];
        _paintLineHighlight(
          canvas,
          size,
          index: exitIndex,
          metric: metric,
          maskPainter: metric.textMaskPainter,
          lineMetrics: metric.metrics,
          textPainter: metric.textPainter,
          highlightTotalWidth: double.infinity,
          animationOpacity: 1.0 - switchState.exitAnimationValue,
        );
      }
    }
  }

  void _paintLineHighlight(
    Canvas canvas,
    Size size, {
    required int index,
    required LineMetrics metric,
    required TextPainter maskPainter,
    required List<ui.LineMetrics> lineMetrics,
    required TextPainter textPainter,
    required double highlightTotalWidth,
    required double animationOpacity,
  }) {
    if (animationOpacity <= 0) return;
    final originY = lineTopY(index);
    final originX = calcContentAliginOffset(textPainter.width, size.width);
    // 渐隐必须在屏幕坐标下应用：先判断该行是否落在渐隐带内，
    // 落在其中时把高亮画进一个按行位置限定的小离屏层，
    // 再把画布恢复到屏幕坐标做 dstOut 擦除。
    final lineRect = Rect.fromLTWH(
      0,
      originY - 32,
      size.width,
      (metric.activeHeight > metric.height
              ? metric.activeHeight
              : metric.height) +
          64,
    ).intersect(Offset.zero & size);
    final needsFade = hasEdgeFade && intersectsEdgeFade(lineRect, size);
    canvas.save();
    if (needsFade) {
      canvas.saveLayer(lineRect, Paint());
    }
    canvas.save();
    canvas.translate(0, originY);
    canvas.translate(originX, 0);
    handleSwitchAnimation(canvas, metric, index, switchState, textPainter, size);
    drawHighlight(
      canvas,
      size,
      maskPainter,
      lineMetrics,
      highlightTotalWidth: highlightTotalWidth,
      animationOpacity: animationOpacity,
    );
    canvas.restore();
    if (needsFade) {
      paintEdgeFade(canvas, size);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LyricHighlightPainter oldDelegate) {
    return shouldRepaintCommon(oldDelegate) ||
        activeHighlightWidth != oldDelegate.activeHighlightWidth;
  }
}
