import 'package:flutter/material.dart';

import '../../core/offline_queue.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../performance/performance_tabs.dart';
import '../self_service/self_service_screen.dart' show SelfServiceButton;
import '../shared/inbox_button.dart';
import 'receipts_screen.dart';
import 'registration_screen.dart';
import 'route_screen.dart';
import 'widgets/offline_sync.dart';
import 'widgets/sos_button.dart';
import 'widgets/summary_bar.dart';

/// One bottom tab of the collector app, shown only when the tech panel allows [feature].
class _CollectorTab {
  final String feature;
  final NavigationDestination destination;
  final Widget view;
  const _CollectorTab(this.feature, this.destination, this.view);
}

/// Field collector app: registration, periodic route, today's receipts.
/// The sector comes from the server (not chosen by the collector).
class CollectorHome extends StatefulWidget {
  const CollectorHome({super.key});

  @override
  State<CollectorHome> createState() => _CollectorHomeState();
}

class _CollectorHomeState extends State<CollectorHome> {
  int _index = 0;
  final _routeKey = GlobalKey<RouteScreenState>();
  final _receiptsKey = GlobalKey<ReceiptsScreenState>();
  final _summaryKey = GlobalKey<SummaryBarState>();
  final _coachKey = GlobalKey<CoachCardState>();

  @override
  void initState() {
    super.initState();
    // mobile: open the offline queue, follow connectivity and send anything left from before
    if (OfflineQueue.supported) OfflineQueue.instance.init();
  }

  List<_CollectorTab> get _tabs {
    final s = Session.instance;
    return [
      if (s.can('collector.register'))
        _CollectorTab(
          'collector.register',
          const NavigationDestination(
            icon: Icon(Icons.person_add_alt_1_outlined),
            selectedIcon: Icon(Icons.person_add_alt_1),
            label: 'تسجيل المواطنين',
          ),
          RegistrationScreen(onCollected: _reloadTop),
        ),
      if (s.can('collector.collect'))
        _CollectorTab(
          'collector.collect',
          const NavigationDestination(icon: Icon(Icons.route_outlined), selectedIcon: Icon(Icons.route), label: 'الجباية الدورية'),
          RouteScreen(key: _routeKey, onCollected: _reloadTop),
        ),
      if (s.can('collector.receipts'))
        _CollectorTab(
          'collector.receipts',
          const NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'وصولاتي',
          ),
          ReceiptsScreen(key: _receiptsKey),
        ),
    ];
  }

  void _reloadTop() {
    _summaryKey.currentState?.reload();
    _coachKey.currentState?.reload();
  }

  void _refreshAll() {
    _reloadTop();
    final tabs = _tabs;
    if (_index >= tabs.length) return;
    final f = tabs[_index].feature;
    if (f == 'collector.collect') _routeKey.currentState?.reload();
    if (f == 'collector.receipts') _receiptsKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = Session.instance;
    final tabs = _tabs;
    final index = tabs.isEmpty ? 0 : _index.clamp(0, tabs.length - 1);
    return Scaffold(
      appBar: portalAppBar(
        title: s.sectorName.isEmpty ? 'لا يوجد قاطع' : s.sectorName,
        subtitle: s.fullName.isEmpty ? s.employeeCode : '${s.fullName}  ·  ${s.employeeCode}',
        color: AppColors.collector,
        actions: [
          SosButton(onSent: _reloadTop),
          const OfflineSyncButton(),
          const InboxButton(),
          const SelfServiceButton(),
          PopupMenuButton<String>(
            tooltip: 'المزيد',
            onSelected: (v) {
              if (v == 'refresh') _refreshAll();
              if (v == 'logout') Session.logout(context);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'refresh', child: ListTile(leading: Icon(Icons.refresh), title: Text('تحديث'))),
              PopupMenuItem(value: 'logout', child: ListTile(leading: Icon(Icons.logout), title: Text('تسجيل الخروج'))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          SummaryBar(key: _summaryKey),
          if (s.can('collector.coach')) CoachCard(key: _coachKey),
          const OfflineStrip(),
          const Divider(height: 1),
          Expanded(
            child: tabs.isEmpty
                ? const EmptyState(
                    icon: Icons.lock_outline,
                    title: 'لا توجد أقسام مفعلة لحسابك',
                    message: 'راجع الإدارة التقنية',
                  )
                : IndexedStack(
                    index: index,
                    children: [for (final t in tabs) t.view],
                  ),
          ),
        ],
      ),
      // NavigationBar needs at least two destinations.
      bottomNavigationBar: tabs.length < 2
          ? null
          : NavigationBar(
              selectedIndex: index,
              onDestinationSelected: (i) {
                setState(() => _index = i);
                _refreshAll();
              },
              destinations: [for (final t in tabs) t.destination],
            ),
    );
  }
}
