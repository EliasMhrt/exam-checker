import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/main.dart';

void main() {
  testWidgets('Answer key screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const ExamCheckerApp());

    expect(find.text('Answer key'), findsOneWidget);
    expect(find.text('Mark the answer grid'), findsOneWidget);
  });

  testWidgets('a clean key enables the button', (WidgetTester tester) async {
    await tester.pumpWidget(const ExamCheckerApp());

    await tester.enterText(
      find.byType(TextField).first,
      '1. A\n2. C\n3. B\n4. D\n5. A',
    );
    await tester.pump();

    // The report says how many answers were read and shows them back, so the
    // teacher can check the parse rather than trusting it.
    expect(find.textContaining('5 of question 5 answered'), findsOneWidget);

    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Mark the answer grid'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('a key with a gap is reported, not silently renumbered',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ExamCheckerApp());

    await tester.enterText(find.byType(TextField).first, '1. A\n2. B\n4. D');
    await tester.pump();

    // Question 4 must still be shown as D on 4. If the parse closed the gap it
    // would read 3. D, which is a wrong mark presented as a right one.
    // Matched exactly, because a loose search also hits the text field, which
    // still holds the teacher's original typing.
    expect(find.text('1. A   2. B   4. D'), findsOneWidget);
    expect(find.text('1. A   2. B   3. D'), findsNothing);
    expect(
      find.textContaining('no answer for question 3'),
      findsOneWidget,
    );
  });

  testWidgets('one-line numbered input keeps every answer',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ExamCheckerApp());

    await tester.enterText(find.byType(TextField).first, '1. A 2. B 3. C');
    await tester.pump();

    expect(find.textContaining('3 of question 3 answered'), findsOneWidget);
  });
}
