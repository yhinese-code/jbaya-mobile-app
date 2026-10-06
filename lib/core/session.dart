import 'package:flutter/material.dart';

import '../features/auth/login_screen.dart';
import 'api_client.dart';
import 'tracking_service.dart';

/// The logged-in employee, as returned by POST /auth/login.
class Session {
  Session._();
  static final Session instance = Session._();

  Map<String, dynamic>? user;

  String get employeeCode => (user?['employee_code'] ?? '').toString();
  String get fullName => (user?['full_name'] ?? '').toString();
  String get role => (user?['role'] ?? '').toString();
  String get sectorName => (user?['sector_name'] ?? '').toString();

  void start(String token, Map<String, dynamic> userData) {
    ApiClient.instance.setToken(token);
    user = userData;
    if (role == 'collector' || role == 'supervisor') {
      TrackingService.instance.start();
    }
  }

  static void logout(BuildContext context) {
    TrackingService.instance.stop();
    ApiClient.instance.setToken(null);
    instance.user = null;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }
}

/// Logout button used in every portal's AppBar.
class LogoutButton extends StatelessWidget {
  const LogoutButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'تسجيل الخروج',
      icon: const Icon(Icons.logout),
      onPressed: () => Session.logout(context),
    );
  }
}
