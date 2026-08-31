import 'package:flutter_test/flutter_test.dart';
import 'package:penbridge/main.dart';

void main() {
  testWidgets('shows the platform landing page', (tester) async {
    await tester.pumpWidget(const PenBridgeApp());
    expect(find.text('Kalem modu'), findsOneWidget);
  });
}
