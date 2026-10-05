import 'package:flutter_test/flutter_test.dart';

import 'package:jbaya_mobile_app/main.dart';

void main() {
  testWidgets('App opens on the login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const JbayaEnterpriseApp());
    expect(find.text('منظومة جباية بغداد المركزية'), findsOneWidget);
    expect(find.text('تسجيل الدخول'), findsOneWidget);
  });
}
