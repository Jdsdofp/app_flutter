import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:epi_kiosk_app/main.dart';

void main() {
  testWidgets('App builds without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const EpiKioskApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}