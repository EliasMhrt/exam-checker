import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/main.dart';

void main() {
  testWidgets('Answer key screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const ExamCheckerApp());

    expect(find.text('Answer key'), findsOneWidget);
    expect(find.text('Open smart camera'), findsOneWidget);
  });

  testWidgets('Answer key parsing enables the button', (WidgetTester tester) async {
    await tester.pumpWidget(const ExamCheckerApp());

    await tester.enterText(
      find.byType(TextField).first,
      '1. A\n2. C\n3. B\n4. D\n5. A',
    );
    await tester.pump();

    expect(find.textContaining('5 questions'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Open smart camera'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNotNull);
  });
}