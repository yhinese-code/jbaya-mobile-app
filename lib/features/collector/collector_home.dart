import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../performance/performance_tabs.dart';
import '../self_service/self_service_screen.dart' show SelfServiceButton;
import '../shared/inbox_button.dart';
import 'receipts_screen.dart';
import 'registration_screen.dart';
import 'route_screen.dart';
import 'widgets/sos_button.dart';
import 'widgets/summary_bar.dart';

/// One bottom tab of the collector app, shown only when the tech panel allows [feature].
class _CollectorTab {
  final String feature;
  final BottomNavigationBarItem item;
  final Widget view;
  const _CollectorTab(this.feature, this.item, this.view);
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

  List<_CollectorTab> get _tabs {
    final s = Session.instance;
    return [
      if (s.can('collector.register'))
        _CollectorTab(
          'collector.register',
          const BottomNavigationBarItem(icon: Icon(Icons.person_add_alt_1), label: 'تسجيل المواطنين'),
          RegistrationScreen(onCollected: _reloadTop),
        ),
      if (s.can('collector.collect'))
        _CollectorTab(
          'collector.collect',
          const BottomNavigationBarItem(icon: Icon(Icons.repeat), label: 'الجباية الدورية'),
          RouteScreen(key: _routeKey, onCollected: _reloadTop),
        ),
      if (s.can('collector.receipts'))
        _CollectorTab(
          'collector.receipts',
          const BottomNavigationBarItem(icon: Icon(Icons.receipt_long), label: 'وصولاتي'),
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
      appBar: AppBar(
        title: Text(
          '${s.sectorName.isEmpty ? 'لا يوجد قاطع' : s.sectorName}  |  ${s.employeeCode}',
          style: const TextStyle(fontSize: 16),
        ),
        backgroundColor: const Color(0xFF004D40),
        foregroundColor: Colors.white,
        actions: [
          SosButton(onSent: _reloadTop),
          const InboxButton(),
          const SelfServiceButton(),
          IconButton(tooltip: 'تحديث', icon: const Icon(Icons.refresh), onPressed: _refreshAll),
          const LogoutButton(),
        ],
      ),
      body: Column(
        children: [
          SummaryBar(key: _summaryKey),
          if (s.can('collector.coach')) CoachCard(key: _coachKey),
          const Divider(height: 1),
          Expanded(
            child: tabs.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('لا توجد أقسام مفعلة لحسابك. راجع الإدارة التقنية', textAlign: TextAlign.center),
                    ),
                  )
                : IndexedStack(
                    index: index,
                    children: [for (final t in tabs) t.view],
                  ),
          ),
        ],
      ),
      // BottomNavigationBar needs at least two items.
      bottomNavigationBar: tabs.length < 2
          ? null
          : BottomNavigationBar(
              currentIndex: index,
              onTap: (i) {
                setState(() => _index = i);
                _refreshAll();
              },
              selectedItemColor: const Color(0xFF004D40),
              items: [for (final t in tabs) t.item],
            ),
    );
  }
}
