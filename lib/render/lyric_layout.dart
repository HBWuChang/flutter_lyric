import 'package:flutter/rendering.dart';
import 'package:flutter_lyric/core/lyric_model.dart';
import 'package:flutter_lyric/core/lyric_style.dart';

class LyricLayout {
  /// 调试用：真正执行布局计算的次数（缓存命中不计数）
  static int debugComputeCount = 0;

  final List<LineMetrics> metrics;
  final LyricStyle style;
  final Size viewSize;
  final double selectionAnchorPosition;
  final double activeAnchorPosition;

  LyricLayout copyWith(LyricStyle style) {
    return LyricLayout._internal(
      metrics,
      style,
      viewSize,
      selectionAnchorPosition,
      activeAnchorPosition,
    );
  }

  @override
  String toString() {
    return 'LyricLayout(metrics: $metrics, style: $style)';
  }

  double lineOffsetY(int index, int activeIndex, double anchorPosition,
      MainAxisAlignment alignment) {
    double indexStartY = 0;
    for (var i = 0; i < metrics.length; i++) {
      final lineHeight = getLineHeight(i == activeIndex, i);
      if (i >= index) {
        final anchorOffset =
            anchorOffsetY(i, activeIndex == i, lineHeight, alignment);
        indexStartY += anchorOffset;
        break;
      }
      indexStartY += lineHeight + style.lineGap;
    }

    if (anchorPosition < indexStartY + style.contentPadding.top) {
      return indexStartY - anchorPosition;
    }
    return -style.contentPadding.top;
  }

  // 用于修正Anchor对齐的偏移量
  double anchorAdjustmentOffsetY(int index, int activeIndex) {
    final isHighlight = index == activeIndex;
    final lineHeight = getLineHeight(isHighlight, index);
    var anchorOffset =
        anchorOffsetY(index, isHighlight, lineHeight, style.selectionAlignment);
    return (lineHeight / 2 - anchorOffset);
  }

  double anchorOffsetY(
    int index,
    bool isHighlight,
    double? lineHeight,
    MainAxisAlignment? alignment,
  ) {
    if (metrics.isEmpty || index < 0 || index >= metrics.length) return 0;
    final lh = lineHeight ?? getLineHeight(isHighlight, index);
    final hasTranslation = metrics[index].translationHeight > 0;
    final align = hasTranslation
        ? (alignment ?? style.selectionAlignment)
        : MainAxisAlignment.start;
    final currentLine = metrics[index];
    final activeHeight =
        isHighlight ? currentLine.activeHeight : currentLine.height;
    if (align == MainAxisAlignment.start) {
      return activeHeight / 2;
    } else if (align == MainAxisAlignment.end) {
      return activeHeight +
          style.translationLineGap +
          currentLine.translationHeight / 2;
    } else if (align == MainAxisAlignment.center) {
      return lh / 2;
    }
    return 0;
  }

  double getLineHeight(bool isHighlight, int index) {
    if (metrics.isEmpty || index < 0 || index >= metrics.length) return 0;
    final mainHeight =
        isHighlight ? metrics[index].activeHeight : metrics[index].height;
    if (metrics[index].translationHeight == 0) {
      return mainHeight;
    }
    return mainHeight +
        metrics[index].translationHeight +
        style.translationLineGap;
  }

  double contentHeight(int highlightIndex) {
    double totalHeight = 0;
    for (var i = 0; i < metrics.length; i++) {
      totalHeight += getLineHeight(i == highlightIndex, i);
      if (i < metrics.length - 1) {
        totalHeight += style.lineGap;
      }
    }
    return totalHeight + style.contentPadding.vertical;
  }

  LyricLayout._internal(
    this.metrics,
    this.style,
    this.viewSize,
    this.selectionAnchorPosition,
    this.activeAnchorPosition,
  );

  /// 系统字体变化后重新测量「普通文本」。
  ///
  /// 高亮 / 遮罩度量保持懒构建，这里直接丢弃旧缓存，绘制时按新字体重建。
  factory LyricLayout.updatePainters(
    LyricLayout layout,
  ) {
    final maxWidth = layout.viewSize.width;
    final lineMetrics = <LineMetrics>[];
    for (var line in layout.metrics) {
      final textPainter = line.textPainter;
      textPainter.markNeedsLayout();
      textPainter.layout(maxWidth: maxWidth);
      final translationTextPainter = line.translationTextPainter;
      final hasTranslation = translationTextPainter.text != null;
      if (hasTranslation) {
        translationTextPainter.markNeedsLayout();
        translationTextPainter.layout(maxWidth: maxWidth);
      }
      final updated = LineMetrics(
        line: line.line,
        height: textPainter.height,
        width: textPainter.width,
        translationWidth: hasTranslation ? translationTextPainter.width : 0,
        translationHeight: hasTranslation ? translationTextPainter.height : 0,
        textPainter: textPainter,
        translationTextPainter: translationTextPainter,
        maxWidth: maxWidth,
        style: layout.style,
      );
      if (line.line.words != null) {
        updated.words = _calcWordMetrics(line.line, textPainter,
            updated.activeTextPainter, translationTextPainter);
      }
      lineMetrics.add(updated);
    }
    return LyricLayout._internal(
      lineMetrics,
      layout.style,
      layout.viewSize,
      layout.selectionAnchorPosition,
      layout.activeAnchorPosition,
    );
  }

  static TextPainter createHighlightMaskPainter(
    TextPainter sourcePainter,
    double maxWidth,
  ) {
    final maskPainter = TextPainter(
      text: buildHighlightMaskTextSpan(sourcePainter.text! as TextSpan),
      textAlign: sourcePainter.textAlign,
      textDirection: sourcePainter.textDirection,
    );
    maskPainter.layout(maxWidth: maxWidth);
    return maskPainter;
  }

  static TextSpan buildHighlightMaskTextSpan(TextSpan source) {
    final style = source.style;
    return TextSpan(
      text: source.text,
      children: source.children?.map((child) {
        return child is TextSpan ? buildHighlightMaskTextSpan(child) : child;
      }).toList(),
      style: style?.copyWith(
        color: (style.color ?? const Color(0xFFFFFFFF)).withValues(alpha: 1.0),
      ),
    );
  }

  static List<WordMetrics>? _calcWordMetrics(
      LyricLine line,
      TextPainter textPainter,
      TextPainter activeTextPainter,
      TextPainter translationTextPainter) {
    var currentOffset = 0;
    final words = line.words?.map((word) {
      // 从当前位置开始查找单词，确保按顺序匹配
      final wordStart = line.text.indexOf(word.text, currentOffset);
      if (wordStart == -1) {
        // 如果找不到单词，使用默认值
        return WordMetrics(
          word: word,
          width: 0,
          height: textPainter.height,
          highlightWidth: 0,
          highlightHeight: activeTextPainter.height,
        );
      }
      final wordEnd = wordStart + word.text.length;
      // 更新当前位置，为下一个单词查找做准备
      currentOffset = wordEnd;

      // 使用 textPainter 获取普通样式的文本框
      final textSelection =
          TextSelection(baseOffset: wordStart, extentOffset: wordEnd);
      final textBoxes = textPainter.getBoxesForSelection(textSelection);
      var tWidth = 0.0;
      var tHeight = 0.0;
      calcWordSize(List<TextBox> boxs) {
        tWidth = 0.0;
        tHeight = 0.0;
        var h = 0;
        for (var box in boxs) {
          final rect = box.toRect();
          tWidth += rect.width;
          if (rect.height > h) {
            tHeight = rect.height;
          }
        }
      }

      calcWordSize(textBoxes);
      final width = tWidth;
      final wordHeight = tHeight;

      // 使用 activeTextPainter 获取高亮样式的文本框
      final activeBoxes = activeTextPainter.getBoxesForSelection(textSelection);
      calcWordSize(activeBoxes);
      final highlightWidth = tWidth;
      final wordHighlightHeight = tHeight;

      return WordMetrics(
        word: word,
        width: width,
        height: wordHeight,
        highlightWidth: highlightWidth,
        highlightHeight: wordHighlightHeight,
      );
    }).toList();
    return words;
  }

  /// 计算整首歌词的布局。
  ///
  /// 每行只 eager 测量「普通文本」（绘制任意行都要用），高亮样式与遮罩
  /// 交给 [LineMetrics] 懒构建：只有当前播放行 / 进退场行才会真正用到，
  /// 这样长歌词的首帧布局耗时可以降到原来的 1/3 左右。
  factory LyricLayout.compute(
    LyricModel model,
    LyricStyle style,
    Size viewSize,
  ) {
    debugComputeCount++;
    final maxWidth = viewSize.width;
    final lineMetrics = <LineMetrics>[];
    for (var line in model.lines) {
      final textPainter = TextPainter(
        textAlign: style.lineTextAlign,
        textDirection: TextDirection.ltr,
      );
      textPainter.text = TextSpan(text: line.text, style: style.textStyle);
      textPainter.layout(maxWidth: maxWidth);

      final translationTextPainter = TextPainter(
        textAlign: style.lineTextAlign,
        textDirection: TextDirection.ltr,
      );
      double translationWidth = 0;
      double translationHeight = 0;

      if (line.translation != null) {
        translationTextPainter.text = TextSpan(
          text: line.translation,
          style: style.translationStyle,
        );
        translationTextPainter.layout(maxWidth: maxWidth);
        translationWidth = translationTextPainter.width;
        translationHeight = translationTextPainter.height;
      }
      final lineMetric = LineMetrics(
        line: line,
        height: textPainter.height,
        width: textPainter.width,
        translationWidth: translationWidth,
        translationHeight: translationHeight,
        textPainter: textPainter,
        translationTextPainter: translationTextPainter,
        maxWidth: maxWidth,
        style: style,
      );
      if (line.words != null) {
        lineMetric.words = _calcWordMetrics(
            line, textPainter, lineMetric.activeTextPainter,
            translationTextPainter);
      }
      lineMetrics.add(lineMetric);
    }
    return LyricLayout._internal(
      lineMetrics,
      style,
      viewSize,
      style.calcSelectionAnchorPosition(viewSize.height),
      style.calcActiveAnchorPosition(viewSize.height),
    );
  }
}

class _CachedLayout {
  _CachedLayout(this.model, this.viewSize, this.layout);

  final LyricModel model;
  final Size viewSize;
  final LyricLayout layout;
}

/// 歌词布局缓存。
///
/// 整首歌词的布局（每行至少一次 TextPainter.layout）是歌词页首帧的主要开销，
/// 但 widget 重建（`Visibility` 切换、页面重新进入、外层 setState）并不会
/// 改变歌词模型或尺寸，此时完全可以复用上一次的布局。
///
/// 命中条件：同一个 [LyricModel] 实例 + 相同的 viewSize + 等价样式；
/// 未命中（换歌、改字号、改行距）时才真正执行 [LyricLayout.compute]。
class LyricLayoutCache {
  LyricLayoutCache._();

  /// 最多缓存几份布局（约等于最近听过的几首歌），超出后按 LRU 淘汰
  static const int _maxEntries = 3;

  static final List<_CachedLayout> _entries = <_CachedLayout>[];

  /// 命中则返回缓存布局；样式实例不同但等价时会返回替换样式后的副本。
  static LyricLayout? lookup(
    LyricModel model,
    LyricStyle style,
    Size viewSize,
  ) {
    for (var i = _entries.length - 1; i >= 0; i--) {
      final entry = _entries[i];
      if (!identical(entry.model, model)) continue;
      if (entry.viewSize != viewSize) continue;
      final cachedStyle = entry.layout.style;
      if (!identical(cachedStyle, style) &&
          cachedStyle.compareTo(style) != RenderComparison.identical) {
        continue;
      }
      // LRU：命中后移到队尾
      _entries.removeAt(i);
      _entries.add(entry);
      return identical(cachedStyle, style)
          ? entry.layout
          : entry.layout.copyWith(style);
    }
    return null;
  }

  /// 保存一份布局
  static void store(LyricModel model, Size viewSize, LyricLayout layout) {
    _entries.removeWhere(
      (entry) => identical(entry.model, model) && entry.viewSize == viewSize,
    );
    _entries.add(_CachedLayout(model, viewSize, layout));
    while (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
  }

  /// 布局中的 painter 被就地修改（样式变化、系统字体变化）时调用。
  /// 否则其他视图可能复用到与缓存样式不一致的 painter。
  static void invalidate() {
    _entries.clear();
  }

  /// 当前缓存的布局数量
  static int get length => _entries.length;
}
