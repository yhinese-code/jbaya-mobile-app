import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../shared/alerts_tab.dart';
import 'cc_widgets.dart';
import 'escalations_tab.dart';
import 'health_tab.dart';
import 'live_ops_tab.dart';
import 'master_code_tab.dart';
import 'messages_tab.dart';
import 'performance_tab.dart';
import 'receipts_log_tab.dart';
import 'trail_tab.dart';

/// Central Command: dark "video wall" for the operations room.
/// Login requires a WhatsApp code (two-factor). The screen locks itself after 15 minutes without activity.
class CentralCommandScreen extends StatefulWidget {
  const CentralCommandScreen({super.key});

  @override
  State<CentralCommandScreen> createState() => _CentralCommandScreenState();
}

class _CentralCommandScreenState extends State<CentralCommandScreen> {
  static const _idleLimit = Duration(minutes: 15);

  int _tab = 0;
  String? _trailEmployee;
  Timer? _idleTimer;

  static const _destinations = [
    (Icons.radar, 'العمليات الحية'),
    (Icons.timeline, 'تتبع المسار'),
    (Icons.leaderboard, 'القواطع والأداء'),
    (Icons.receipt_long, 'سجل الإيصالات'),
    (Icons.campaign, 'التوجيهات'),
    (Icons.key, 'الرمز الرئيسي'),
    (Icons.sos, 'الاستغاثات'),
    (Icons.report, 'فروقات نقدية'),
    (Icons.monitor_heart, 'صحة النظام'),
  ];

  @override
  void initState() {
    super.initState();
    _resetIdle();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  void _resetIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleLimit, () {
      if (!mounted) return;
      Session.logout(context);
    });
  }

  void _openTrail(String code) {
    setState(() {
      _trailEmployee = code;
      _tab = 1;
    });
  }

  Widget _body() {
    switch (_tab) {
      case 0:
        return LiveOpsTab(onOpenTrail: _openTrail);
      case 1:
        return TrailTab(initialEmployee: _trailEmployee);
      case 2:
        return const PerformanceTab();
      case 3:
        return const ReceiptsLogTab();
      case 4:
        return const MessagesTab();
      case 5:
        return const MasterCodeTab();
      case 6:
        return const AlertsTab();
      case 7:
        return const EscalationsTab();
      default:
        return const HealthTab();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    return Theme(
      data: CC.theme(context),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _resetIdle(),
        onPointerSignal: (_) => _resetIdle(),
        child: Scaffold(
          appBar: AppBar(
            backgroundColor: CC.panel,
            foregroundColor: CC.text,
            titleSpacing: 16,
            title: const Row(
              children: [
                Icon(Icons.shield_moon, color: CC.accent),
                SizedBox(width: 10),
                Text('القيادة المركزية - منظومة جباية بغداد', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            actions: [
              const Center(child: _Clock()),
              const SizedBox(width: 16),
              Center(child: Text('${s.fullName} (${s.employeeCode})', style: const TextStyle(color: CC.muted))),
              const SizedBox(width: 8),
              const LogoutButton(),
              const SizedBox(width: 8),
            ],
          ),
          body: Row(
            children: [
              SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: MediaQuery.of(context).size.height - kToolbarHeight),
                  child: IntrinsicHeight(
                    child: NavigationRail(
                      selectedIndex: _tab,
                      onDestinationSelected: (i) => setState(() => _tab = i),
                      labelType: NavigationRailLabelType.all,
                      backgroundColor: CC.panel,
                      indicatorColor: CC.accent.withValues(alpha: 0.2),
                      selectedIconTheme: const IconThemeData(color: CC.accent),
                      unselectedIconTheme: const IconThemeData(color: CC.muted),
                      selectedLabelTextStyle: const TextStyle(color: CC.accent, fontWeight: FontWeight.bold, fontSize: 12),
                      unselectedLabelTextStyle: const TextStyle(color: CC.muted, fontSize: 12),
                      destinations: [
                        for (final d in _destinations) NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2)),
                      ],
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }
}


/// Ticking clock in its own widget so the whole Command screen (maps, markers) is not rebuilt every second.
class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  DateTime _now = DateTime.now();
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String two(int v) => v.toString().padLeft(2, '0');
    return Text('${two(_now.hour)}:${two(_now.minute)}:${two(_now.second)}',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, fontFeatures: [FontFeature.tabularFigures()]));
  }
}
