import 'package:better_native_video_player/src/fullscreen/swipe_down_dismissible.dart';
import 'package:flutter/material.dart';
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
    await tester.drag(
      find.byType(SwipeDownDismissible),
      const Offset(0, 200),
    );
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
  });

  testWidgets('a short drag springs back without dismissing', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(buildSubject(onDismissed: () => dismissed = true));
    final restingPosition = tester.getTopLeft(find.text('content'));

    await tester.drag(
      find.byType(SwipeDownDismissible),
      const Offset(0, 40),
    );
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

    await tester.drag(
      find.byType(SwipeDownDismissible),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();

    expect(dismissed, isFalse);
    expect(tester.getTopLeft(find.text('content')), restingPosition);
  });
}
