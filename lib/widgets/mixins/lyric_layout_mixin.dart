import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_controller.dart';
import 'package:flutter_lyric/core/lyric_style.dart';
import 'package:flutter_lyric/render/lyric_layout.dart';

/// 负责歌词布局计算和状态管理的 Mixin
mixin LyricLayoutMixin<T extends StatefulWidget> on State<T> {
  LyricController get controller;
  LyricStyle get style;
  Size get lyricSize;
  set lyricSize(Size value);
  LyricLayout? get layout;
  set layout(LyricLayout? value);

  double contentHeight = 0.0;

  @override
  void dispose() {
    controller.activeIndexNotifiter.removeListener(updateTotalHeight);
    controller.lyricNotifier.removeListener(computeLyricLayout);
    PaintingBinding.instance.systemFonts.removeListener(systemFontsDidChange);
    super.dispose();
  }

  void onStyleChange() {
    final l = layout;
    if (l == null) {
      computeLyricLayout();
      return;
    }
    final oldStyle = l.style;
    final newStyle = style;
    if (oldStyle == newStyle) return;
    layout = l.copyWith(newStyle);
    final comparison = oldStyle.compareTo(newStyle);
    if (comparison == RenderComparison.identical) {
      return;
    }
    if (comparison == RenderComparison.layout) {
      LyricLayoutCache.invalidate();
      computeLyricLayout();
      return;
    }
    if (comparison == RenderComparison.paint) {
      // 只更新已构建的 painter（颜色），未构建的高亮/遮罩保持懒构建
      layout?.metrics.forEach((element) => element.applyStyle(newStyle));
      LyricLayoutCache.invalidate();
      setState(() {});
    }
  }

  @override
  void initState() {
    PaintingBinding.instance.systemFonts.addListener(systemFontsDidChange);
    controller.activeIndexNotifiter.addListener(() {
      scheduleMicrotask(() {
        updateTotalHeight();
      });
    });
    controller.selectedIndexNotifier.addListener(() {
      updateSelection();
    });
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      controller.lyricNotifier.addListener(computeLyricLayout);
    });
    super.initState();
  }

  void updateTotalHeight() {
    contentHeight =
        layout?.contentHeight(controller.activeIndexNotifiter.value) ?? 0;
  }

  void systemFontsDidChange() {
    if (layout == null) return;
    LyricLayoutCache.invalidate();
    onLayoutChange(LyricLayout.updatePainters(layout!));
  }

  void onLayoutChange(LyricLayout layout) {
    this.layout = layout;
    updateSelection();
    updateTotalHeight();
    if (mounted) {
      setState(() {});
    }
  }

  /// 计算歌词布局（命中 [LyricLayoutCache] 时直接复用，不再逐行测量）
  void computeLyricLayout() {
    final lyricModel = controller.lyricNotifier.value;
    if (lyricModel == null) {
      return;
    }
    // 尺寸未就绪时不计算：maxWidth 为 0 会让每个字各占一行
    if (lyricSize.isEmpty) {
      return;
    }
    LyricLayout? computedLayout =
        LyricLayoutCache.lookup(lyricModel, style, lyricSize);
    if (computedLayout == null) {
      computedLayout = LyricLayout.compute(
        lyricModel,
        style,
        lyricSize,
      );
      LyricLayoutCache.store(lyricModel, lyricSize, computedLayout);
    }
    controller.anchorPositionNotifier.value =
        computedLayout.selectionAnchorPosition;
    onLayoutChange(computedLayout);
  }

  void updateSelection() {
    final isHighlight = controller.activeIndexNotifiter.value ==
        controller.selectedIndexNotifier.value;
    scheduleMicrotask(() {
      controller.selectedLineHeightNotifier.value = layout?.getLineHeight(
            isHighlight,
            controller.selectedIndexNotifier.value,
          ) ??
          0;
    });
    controller.anchorAlignOffsetY = layout?.anchorAdjustmentOffsetY(
          controller.selectedIndexNotifier.value,
          controller.activeIndexNotifiter.value,
        ) ??
        0;
    if (layout?.metrics.isEmpty ?? true) {
      return;
    }
    if (controller.selectedIndexNotifier.value < 0 ||
        controller.selectedIndexNotifier.value >=
            (layout?.metrics.length ?? 0)) {
      return;
    }
    final currentLine = layout?.metrics[controller.selectedIndexNotifier.value];
    controller.selectedMaxWidth = max(
      (isHighlight ? currentLine?.activeWidth : currentLine?.width) ?? 0,
      currentLine?.translationWidth ?? 0,
    );
  }
}
