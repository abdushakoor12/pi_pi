import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pi_pi/main.dart';

void main() {
  testWidgets('App renders chat screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp(
      initialThemeMode: ThemeMode.dark,
    ));

    // Verify the app title is present
    expect(find.text('Pi Pi'), findsOneWidget);

    // Verify the input bar is present
    expect(find.byType(TextField), findsOneWidget);
  });
}
