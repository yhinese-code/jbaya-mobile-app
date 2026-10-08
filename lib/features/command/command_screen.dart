import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../finance/fraud_tabs.dart';
import '../performance/performance_tabs.dart';
import '../shared/alerts_tab.dart';
import 'callbacks_tab.dart';
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
/// Sessions end daily on the server (and whenever the tech panel ends them); the device must be approved by the tech
/// panel. Sections follow the tech panel's permission matrix (command.* features).
class CentralCommandScreen extends StatefulWidget {
  const CentralCommandScreen({super.key});

  @override
  State<CentralCommandScreen> createState() => _CentralCommandScreenState();
}

/// One NavigationRail entry, shown only when [feature] is allowed.
class _Section {
  final String feature;
  final IconData icon;
  final String label;
  final Widget Function() builder;
  const _Section(this.feature, this.icon, this.label, this.builder);
}

class _CentralCommandScreenState extends State<CentralCommandScreen> {
  static const _trailFeature = 'command.trail';

  /// Selected section by feature key, so filtering never shifts the selection to another section.
  String? _selected;
  String? _trailEmployee;

  List<_Section> get _sections {
    final all = [
      _Section('command.live', Icons.radar, 'العمليات الحية', () => LiveOpsTab(onOpenTrail: _openTrail)),
      _Section(_trailFeature, Icons.timeline, 'تتبع المسار', () => TrailTab(initialEmployee: _trailEmployee)),
      _Section('command.sectors', Icons.leaderboard, 'القواطع والأداء', () => const PerformanceTab()),
      _Section('command.receipts', Icons.receipt_long, 'سجل الإيصالات', () => const ReceiptsLogTab()),
      _Section('command.messages', Icons.campaign, 'التوجيهات', () => const MessagesTab()),
      _Section('command.master_code', Icons.key, 'الرمز الرئيسي', () => const MasterCodeTab()),
      _Section('command.sos', Icons.sos, 'الاستغاثات', () => const AlertsTab()),
      _Section('command.differences', Icons.report, 'فروقات نقدية', () => const EscalationsTab()),
      _Section('command.fin_risk', Icons.gpp_maybe, 'المخاطر المالية', () => const FinancialRiskCommandTab()),
      _Section('command.performance', Icons.balance, 'الأداء والتعادل', () => const PerformanceMoneyTab()),
      _Section('command.callbacks', Icons.phone_callback, 'الاتصال العشوائي', () => const CallbacksTab()),
      _Section('command.health', Icons.monitor_heart, 'صحة النظام', () => const HealthTab()),
    ];
    return all.where((s) => Session.instance.can(s.feature)).toList();
  }

  void _openTrail(String code) {
    // Deep link from live ops: only when the trail section is allowed for this account.
    if (!_sections.any((s) => s.feature == _trailFeature)) return;
    setState(() {
      _trailEmployee = code;
      _selected = _trailFeature;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    final sections = _sections;
    var index = sections.indexWhere((x) => x.feature == _selected);
    if (index < 0) index = 0;
    return Theme(
      data: CC.theme(context),
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
        body: sections.isEmpty
            ? const Center(
                child: Text('لا توجد أقسام مفعلة لحسابك. راجع الإدارة التقنية', style: TextStyle(color: CC.muted)),
              )
            : Row(
                children: [
                  SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: MediaQuery.of(context).size.height - kToolbarHeight),
                      child: IntrinsicHeight(
                        child: NavigationRail(
                          selectedIndex: index,
                          onDestinationSelected: (i) => setState(() => _selected = sections[i].feature),
                          labelType: NavigationRailLabelType.all,
                          backgroundColor: CC.panel,
                          indicatorColor: CC.accent.withValues(alpha: 0.2),
                          selectedIconTheme: const IconThemeData(color: CC.accent),
                          unselectedIconTheme: const IconThemeData(color: CC.muted),
                          selectedLabelTextStyle: const TextStyle(color: CC.accent, fontWeight: FontWeight.bold, fontSize: 12),
                          unselectedLabelTextStyle: const TextStyle(color: CC.muted, fontSize: 12),
                          destinations: [
                            for (final d in sections) NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: sections[index].builder()),
                ],
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
