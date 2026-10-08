import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'lyric_style.dart';

/// 整首歌词
class LyricModel {
  final Map<String, String> idTags;
  final List<LyricLine> lines;
  LyricModel({Map<String, String>? tags, required this.lines})
      : idTags = tags ?? {};

  LyricModel copyWith(Map<String, String>? tags, List<LyricLine>? lines) {
    return LyricModel(tags: tags ?? idTags, lines: lines ?? this.lines);
  }

  @override
  String toString() {
    return 'LyricModel(idTags: $idTags, lines: $lines)';
  }

  String get title => idTags['ti'] ?? '';
  String get artist => idTags['ar'] ?? '';
  String get album => idTags['al'] ?? '';
  String get by => idTags['by'] ?? '';
  int get offset => int.tryParse(idTags['offset'] ?? '0') ?? 0;
}

/// 单行歌词
class LyricLine {
  final Duration start; // 行开始时间
  final Duration? end; // 行结束时间，可选
  final String text; // 行文本
  final List<LyricWord>? words; // 可选：逐字高亮信息
  // 可选副歌词字段
  final String? translation; // 翻译

  LyricLine({
    required this.start,
    this.end,
    required this.text,
    this.translation,
    this.words,
  });

  @override
  String toString() {
    return 'LyricLine(start: $start, end: $end, text: $text, translation: $translation, words: $words)';
  }
}

/// 单词/逐字信息
class LyricWord {
  final String text; // 单词/字文本
  final Duration start; // 相对于整首歌的起始时间
  final Duration? end; // 相对于整首歌的结束时间

  LyricWord({required this.text, required this.start, this.end});

  @override
  String toString() {
    return 'LyricWord(text: $text, start: $start, end: $end)';
  }
}

// 单行测量结果
class LineMetrics {
  final LyricLine line;

  /// 普通样式的行高 / 行宽（绘制非当前行时使用）
  final double height;
  final double width;

  /// 翻译行宽高（无翻译时为 0）
  final double translationWidth;
  final double translationHeight;

  final TextPainter textPainter;
  final TextPainter translationTextPainter;

  /// 逐字高亮信息（仅逐字歌词有值）
  List<WordMetrics>? words;

  /// 本次布局使用的最大宽度，懒构建高亮相关 painter 时复用
  final double maxWidth;

  /// 当前样式，`active`/`mask` painter 按需构建时取用
  LyricStyle _style;

  // ===================== 懒构建度量 =====================
  // 高亮(active)样式与遮罩(mask)的 TextPainter 布局开销和普通文本相当，
  // 但只有「当前播放行 / 行切换动画的进退场行」才会真正绘制。
  // 整首歌一次性 layout 这些 painter 会让首帧多出几倍耗时（长歌词可达
  // 数百毫秒），因此全部改为按需构建并缓存。
  TextPainter? _activeTextPainter;
  TextPainter? _textMaskPainter;
  TextPainter? _activeMaskPainter;
  double? _activeWidth;
  double? _activeHeight;
  List<ui.LineMetrics>? _activeLineMetrics;
  List<ui.LineMetrics>? _plainLineMetrics;

  LineMetrics({
    required this.line,
    required this.height,
    required this.width,
    required this.textPainter,
    required this.translationTextPainter,
    required this.maxWidth,
    required LyricStyle style,
    this.translationWidth = 0,
    this.translationHeight = 0,
    this.words,
    TextPainter? activeTextPainter,
    TextPainter? textMaskPainter,
    TextPainter? activeMaskPainter,
    double? activeWidth,
    double? activeHeight,
    List<ui.LineMetrics>? activeMetrics,
    List<ui.LineMetrics>? metrics,
  })  : _style = style,
        _activeTextPainter = activeTextPainter,
        _textMaskPainter = textMaskPainter,
        _activeMaskPainter = activeMaskPainter,
        _activeWidth = activeWidth,
        _activeHeight = activeHeight,
        _activeLineMetrics = activeMetrics,
        _plainLineMetrics = metrics;

  LyricStyle get style => _style;

  /// 调试用：高亮样式 painter 是否已经按需构建
  bool get debugActivePaintersBuilt => _activeTextPainter != null;

  /// 调试用：遮罩 painter 是否已经按需构建
  bool get debugMaskPaintersBuilt =>
      _textMaskPainter != null || _activeMaskPainter != null;

  /// 高亮样式文本绘制器（首次访问时构建）
  TextPainter get activeTextPainter =>
      _activeTextPainter ??= _buildTextPainter(_style.activeStyle);

  /// 普通文本的高亮遮罩（行切换动画的退场行使用）
  TextPainter get textMaskPainter => _textMaskPainter ??=
      _buildTextPainter(_style.textStyle, mask: true);

  /// 高亮文本的高亮遮罩（当前播放行使用）
  TextPainter get activeMaskPainter =>
      _activeMaskPainter ??= _buildTextPainter(_style.activeStyle, mask: true);

  TextPainter _buildTextPainter(TextStyle textStyle, {bool mask = false}) {
    final TextStyle style = mask
        ? textStyle.copyWith(
            color: (textStyle.color ?? const Color(0xFFFFFFFF))
                .withValues(alpha: 1.0),
          )
        : textStyle;
    final TextPainter painter = TextPainter(
      textAlign: _style.lineTextAlign,
      textDirection: TextDirection.ltr,
    );
    painter.text = TextSpan(text: line.text, style: style);
    painter.layout(maxWidth: maxWidth);
    return painter;
  }

  double get activeWidth => _activeWidth ??= activeTextPainter.width;

  double get activeHeight => _activeHeight ??= activeTextPainter.height;

  List<ui.LineMetrics> get activeMetrics =>
      _activeLineMetrics ??= activeTextPainter.computeLineMetrics();

  List<ui.LineMetrics> get metrics =>
      _plainLineMetrics ??= textPainter.computeLineMetrics();

  /// 仅「绘制相关」的样式发生变化时就地更新 painter。
  ///
  /// 尚未构建的高亮 / 遮罩 painter 不在这里创建（保持懒构建），
  /// 只在已构建时同步新的颜色，避免样式变化退化成整首歌词重新 layout。
  void applyStyle(LyricStyle style) {
    _style = style;
    textPainter.text = TextSpan(text: line.text, style: style.textStyle);
    translationTextPainter.text =
        TextSpan(text: line.translation, style: style.translationStyle);
    final TextPainter? active = _activeTextPainter;
    if (active != null) {
      active.text = TextSpan(text: line.text, style: style.activeStyle);
      // 行宽/行高需要按新样式重新测量
      _activeWidth = null;
      _activeHeight = null;
      _activeLineMetrics = null;
    }
    // 遮罩基于字体样式，颜色变化后直接丢弃，绘制时按新样式重建
    _textMaskPainter = null;
    _activeMaskPainter = null;
  }

  @override
  String toString() {
    return 'LineMetrics(line: $line, height: $height, width: $width, highlightWidth: $activeWidth, highlightHeight: $activeHeight, translationWidth: $translationWidth, translationHeight: $translationHeight, words: $words)';
  }

  LineMetrics copyWith({
    LyricLine? line,
    double? height,
    double? width,
    double? activeWidth,
    double? activeHeight,
    double? translationWidth,
    double? translationHeight,
    List<ui.LineMetrics>? activeMetrics,
    List<ui.LineMetrics>? metrics,
    TextPainter? textPainter,
    TextPainter? activeTextPainter,
    TextPainter? textMaskPainter,
    TextPainter? activeMaskPainter,
    TextPainter? translationTextPainter,
    List<WordMetrics>? words,
  }) {
    return LineMetrics(
      line: line ?? this.line,
      height: height ?? this.height,
      width: width ?? this.width,
      translationWidth: translationWidth ?? this.translationWidth,
      translationHeight: translationHeight ?? this.translationHeight,
      textPainter: textPainter ?? this.textPainter,
      translationTextPainter:
          translationTextPainter ?? this.translationTextPainter,
      maxWidth: maxWidth,
      style: _style,
      words: words ?? this.words,
      activeTextPainter: activeTextPainter ?? _activeTextPainter,
      textMaskPainter: textMaskPainter ?? _textMaskPainter,
      activeMaskPainter: activeMaskPainter ?? _activeMaskPainter,
      activeWidth: activeWidth ?? _activeWidth,
      activeHeight: activeHeight ?? _activeHeight,
      activeMetrics: activeMetrics ?? _activeLineMetrics,
      metrics: metrics ?? _plainLineMetrics,
    );
  }
}

class WordMetrics {
  final double width;
  final double height;
  final LyricWord word;
  final double highlightWidth;
  final double highlightHeight;

  WordMetrics({
    required this.word,
    required this.width,
    required this.height,
    required this.highlightWidth,
    required this.highlightHeight,
  });

  @override
  String toString() {
    return 'WordMetrics(word: $word, width: $width, height: $height, highlightWidth: $highlightWidth, highlightHeight: $highlightHeight)';
  }
}

class LyricTag {
  final String tag;
  final String value;

  LyricTag({required this.tag, required this.value});
}
