import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_model.dart';
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:flutter_lyric/render/lyric_layout.dart';
import 'package:flutter_test/flutter_test.dart';

LyricModel buildModel(int lineCount) {
  return LyricModel(
    lines: List<LyricLine>.generate(
      lineCount,
      (i) => LyricLine(
        start: Duration(milliseconds: i * 500),
        text: '第$i行歌词内容，用来测量文本布局开销',
        translation: 'line $i translation',
      ),
    ),
  );
}

Widget buildView(LyricController controller, {LyricStyle? style, Key? key}) {
  return MaterialApp(
    home: SizedBox(
      width: 300,
      height: 600,
      child: LyricView(controller: controller, style: style, key: key),
    ),
  );
}

void main() {
  testWidgets('重复挂载歌词视图时复用布局缓存', (tester) async {
    final controller = LyricController()..loadLyricModel(buildModel(60));

    await tester.pumpWidget(buildView(controller));
    await tester.pump();
    final firstComputeCount = LyricLayout.debugComputeCount;
    expect(firstComputeCount, greaterThan(0));
    expect(LyricLayoutCache.length, greaterThan(0));

    // 销毁再重建（等价于 Visibility 折叠后再展开）
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpWidget(buildView(controller));
    await tester.pump();

    expect(LyricLayout.debugComputeCount, firstComputeCount);
  });

  testWidgets('换歌后重新计算布局', (tester) async {
    final controller = LyricController()..loadLyricModel(buildModel(10));

    await tester.pumpWidget(buildView(controller));
    await tester.pump();
    final firstComputeCount = LyricLayout.debugComputeCount;

    controller.loadLyricModel(buildModel(10));
    await tester.pump();
    await tester.pump();

    expect(LyricLayout.debugComputeCount, firstComputeCount + 1);
  });

  test('布局阶段只测量普通文本，高亮/遮罩按需构建', () {
    final layout = LyricLayout.compute(
      buildModel(20),
      LyricStyles.default2,
      const Size(320, 600),
    );
    final first = layout.metrics.first;

    expect(first.debugActivePaintersBuilt, isFalse);
    expect(first.debugMaskPaintersBuilt, isFalse);
    // 普通文本仍然在布局阶段测量完成
    expect(first.width, greaterThan(0));
    expect(first.height, greaterThan(0));

    // 访问后才构建，且数值可用
    expect(first.activeHeight, greaterThan(first.height));
    expect(first.activeWidth, greaterThan(0));
    expect(first.activeMetrics, isNotEmpty);
    expect(first.debugActivePaintersBuilt, isTrue);

    // 未访问的行保持懒构建
    expect(layout.metrics[10].debugActivePaintersBuilt, isFalse);
  });

  testWidgets('懒构建的高亮/遮罩 painter 可在绘制时按需生成', (tester) async {
    final controller = LyricController()..loadLyricModel(buildModel(20));

    await tester.pumpWidget(
      buildView(controller, style: LyricStyles.default2),
    );
    await tester.pump();

    controller.activeIndexNotifiter.value = 3;
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('仅绘制样式变化时不重新测量整首歌词', (tester) async {
    final controller = LyricController()..loadLyricModel(buildModel(20));
    final style = LyricStyles.default2.copyWith();

    await tester.pumpWidget(buildView(controller, style: style));
    await tester.pump();
    final computeCount = LyricLayout.debugComputeCount;

    // 只改颜色 -> RenderComparison.paint
    await tester.pumpWidget(
      buildView(
        controller,
        style: style.copyWith(
          textStyle: style.textStyle.copyWith(color: Colors.red),
        ),
      ),
    );
    await tester.pump();

    expect(LyricLayout.debugComputeCount, computeCount);
    expect(tester.takeException(), isNull);
  });
}
