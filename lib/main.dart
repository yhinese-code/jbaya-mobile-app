import 'package:flutter/material.dart';

import 'features/auth/login_screen.dart';

// Project layout (Phase 0):
//   lib/core/        API client, session, config, formatting, GPS
//   lib/features/    one folder per portal: auth, collector, supervisor, finance, command
// Run the backend first (see jbaya-backend/README.md), then:
//   flutter run -d chrome
//   flutter run --dart-define=API_URL=http://10.0.2.2:8000     (Android emulator)

void main() {
  runApp(const JbayaEnterpriseApp());
}

class JbayaEnterpriseApp extends StatelessWidget {
  const JbayaEnterpriseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'نظام الجباية المركزي',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF004D40)),
        useMaterial3: true,
        fontFamily: 'Tahoma',
      ),
      // Whole app is right-to-left, so individual screens don't need their own Directionality wrapper.
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child ?? const SizedBox()),
      home: const LoginScreen(),
    );
  }
}
