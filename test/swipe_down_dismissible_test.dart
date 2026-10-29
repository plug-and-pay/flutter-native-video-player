import 'package:better_native_video_player/src/fullscreen/swipe_down_dismissible.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildSubject({required VoidCallback onDismissed}) {
    return MaterialApp(
      home: SwipeDownDismissible(
        onDismissed: onDismissed,
        child: const Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: Text('content')),
        ),
      ),
    );
  }

  testWidgets('dragging down past the threshold calls onDismissed', (
    tester,
  ) async {
    var dismissed = false;
    await tester.pumpWidget(buildSubject(onDismissed: () => dismissed = true));

    // Default test surface is 800x600, threshold is 15% of the height (90px).
    await tester.drag(find.byType(SwipeDownDismissible), const Offset(0, 200));
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
  });

  testWidgets('a short drag springs back without dismissing', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(buildSubject(onDismissed: () => dismissed = true));
    final restingPosition = tester.getTopLeft(find.text('content'));

    await tester.drag(find.byType(SwipeDownDismissible), const Offset(0, 40));
    await tester.pumpAndSettle();

    expect(dismissed, isFalse);

    // Content is back at rest.
    expect(tester.getTopLeft(find.text('content')), restingPosition);
  });

  testWidgets('dragging up does not move the content or dismiss', (
    tester,
  ) async {
    var dismissed = false;
    await tester.pumpWidget(buildSubject(onDismissed: () => dismissed = true));
    final restingPosition = tester.getTopLeft(find.text('content'));

    await tester.drag(find.byType(SwipeDownDismissible), const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(dismissed, isFalse);
    expect(tester.getTopLeft(find.text('content')), restingPosition);
  });

  testWidgets('the content follows the finger sideways once it moves down', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject(onDismissed: () {}));
    final restingCenter = tester.getCenter(find.text('content'));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SwipeDownDismissible)),
    );
    await gesture.moveBy(const Offset(0, 30));
    await gesture.moveBy(const Offset(60, 120));
    await tester.pump();

    final center = tester.getCenter(find.text('content'));
    expect(center.dy, greaterThan(restingCenter.dy));
    expect(center.dx, greaterThan(restingCenter.dx + 30));
    await gesture.up();
  });

  testWidgets('a quick flick down dismisses before the threshold', (
    tester,
  ) async {
    var dismissed = false;
    await tester.pumpWidget(buildSubject(onDismissed: () => dismissed = true));

    // 70px is under the 90px threshold, but fast.
    await tester.fling(
      find.byType(SwipeDownDismissible),
      const Offset(0, 70),
      2000,
    );
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
  });

  testWidgets('reports drag start, cancel and progress', (tester) async {
    var started = 0;
    var cancelled = 0;
    final progress = ValueNotifier<double>(0);
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SwipeDownDismissible(
          onDismissed: () {},
          onDragStart: () => started++,
          onDragCancel: () => cancelled++,
          dragProgress: progress,
          child: const Scaffold(body: Center(child: Text('content'))),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SwipeDownDismissible)),
    );
    await gesture.moveBy(const Offset(0, 30));
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    expect(started, 1);
    expect(progress.value, greaterThan(0));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(cancelled, 1);
    expect(progress.value, 0);
  });
}
