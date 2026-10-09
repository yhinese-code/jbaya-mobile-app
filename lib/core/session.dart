import 'package:flutter/material.dart';

import '../features/auth/login_screen.dart';
import 'api_client.dart';
import 'theme.dart';
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
  bool get hasSector => user?['sector_id'] != null;

  /// Tabs the tech panel allows for this role (everything is allowed unless switched off there).
  bool can(String feature) {
    final p = user?['permissions'];
    if (p is Map && p.containsKey(feature)) return p[feature] == true;
    return true;
  }

  void start(String token, Map<String, dynamic> userData) {
    ApiClient.instance.setToken(token);
    user = userData;
    if (role == 'collector' || role == 'supervisor') {
      TrackingService.instance.start();
    }
  }

  static void logout(BuildContext context) {
    if (ApiClient.instance.hasToken) {
      ApiClient.instance.post('/auth/logout').catchError((_) => null);   // end the session on the server too
    }
    _clear();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  static void _clear() {
    TrackingService.instance.stop();
    ApiClient.instance.setToken(null);
    instance.user = null;
  }

  /// The server ended the session (daily logout at midnight, tech panel, revoked device): back to the login screen.
  static void sessionEnded(NavigatorState? nav, String message) {
    if (instance.user == null) return;
    _clear();
    nav?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginScreen(notice: message)),
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


/// One tab of a portal, shown only when the tech panel allows [feature] for this role.
class PortalTab {
  final String feature;
  final Tab tab;
  final Widget view;
  const PortalTab(this.feature, this.tab, this.view);
}

/// A TabBar + TabBarView portal whose tabs follow the permission matrix.
class PermittedTabs extends StatelessWidget {
  final List<PortalTab> tabs;
  /// Builds the AppBar; put [bar] in its `bottom` (null when no tab is allowed).
  final PreferredSizeWidget Function(TabBar? bar) appBar;
  final Color indicator;
  const PermittedTabs({super.key, required this.tabs, required this.appBar, this.indicator = Colors.white});

  @override
  Widget build(BuildContext context) {
    final shown = tabs.where((t) => Session.instance.can(t.feature)).toList();
    if (shown.isEmpty) {
      return Scaffold(
        appBar: appBar(null),
        body: const EmptyState(
          icon: Icons.lock_outline,
          title: 'لا توجد أقسام مفعلة لحسابك',
          message: 'راجع الإدارة التقنية لتفعيل الأقسام المطلوبة',
        ),
      );
    }
    return DefaultTabController(
      length: shown.length,
      child: Scaffold(
        appBar: appBar(TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white.withValues(alpha: 0.78),
          indicatorColor: indicator,
          indicatorWeight: 3,
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontWeight: FontWeight.w700, fontSize: 14),
          unselectedLabelStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontWeight: FontWeight.w500, fontSize: 14),
          labelPadding: const EdgeInsets.symmetric(horizontal: Gap.md),
          dividerColor: Colors.transparent,
          tabs: [for (final t in shown) t.tab],
        )),
        // no swipe between tabs: maps and lists inside the tabs need the drag gestures
        body: TabBarView(physics: const NeverScrollableScrollPhysics(), children: [for (final t in shown) t.view]),
      ),
    );
  }
}
