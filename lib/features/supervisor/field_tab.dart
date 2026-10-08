import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../collector/receipts_screen.dart';
import '../collector/registration_screen.dart';
import '../collector/route_screen.dart';
import '../collector/widgets/summary_bar.dart';
import '../performance/performance_tabs.dart';

/// The supervisor's own field work: he collects with the same quota as his collectors.
/// Reuses the collector screens (registration, route, receipts) under one small switcher.
class SupervisorFieldTab extends StatefulWidget {
  const SupervisorFieldTab({super.key});

  @override
  State<SupervisorFieldTab> createState() => _SupervisorFieldTabState();
}

class _SupervisorFieldTabState extends State<SupervisorFieldTab> with AutomaticKeepAliveClientMixin {
  int _index = 0;
  final _routeKey = GlobalKey<RouteScreenState>();
  final _receiptsKey = GlobalKey<ReceiptsScreenState>();
  final _summaryKey = GlobalKey<SummaryBarState>();
  final _coachKey = GlobalKey<CoachCardState>();

  // Keep a half-finished registration / collection alive while the supervisor visits other tabs.
  @override
  bool get wantKeepAlive => true;

  void _reloadTop() {
    _summaryKey.currentState?.reload();
    _coachKey.currentState?.reload();
  }

  void _refreshAll() {
    _reloadTop();
    if (_index == 1) _routeKey.currentState?.reload();
    if (_index == 2) _receiptsKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!Session.instance.hasSector) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'لم يُحدد لك قاطع للعمل الميداني. راجع الإدارة التقنية',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }
    return Column(
      children: [
        SummaryBar(key: _summaryKey),
        CoachCard(key: _coachKey),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 0, icon: Icon(Icons.person_add_alt_1), label: Text('التسجيل')),
                    ButtonSegment(value: 1, icon: Icon(Icons.repeat), label: Text('الجباية')),
                    ButtonSegment(value: 2, icon: Icon(Icons.receipt_long), label: Text('وصولاتي')),
                  ],
                  selected: {_index},
                  onSelectionChanged: (s) {
                    setState(() => _index = s.first);
                    _refreshAll();
                  },
                ),
              ),
              IconButton(tooltip: 'تحديث', icon: const Icon(Icons.refresh), onPressed: _refreshAll),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _index,
            children: [
              RegistrationScreen(onCollected: _reloadTop),
              RouteScreen(key: _routeKey, onCollected: _reloadTop),
              ReceiptsScreen(key: _receiptsKey),
            ],
          ),
        ),
      ],
    );
  }
}
