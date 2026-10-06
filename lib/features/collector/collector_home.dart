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
    final s = Session.instance;
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
          CoachCard(key: _coachKey),
          const Divider(height: 1),
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
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) {
          setState(() => _index = i);
          _refreshAll();
        },
        selectedItemColor: const Color(0xFF004D40),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.person_add_alt_1), label: 'تسجيل المواطنين'),
          BottomNavigationBarItem(icon: Icon(Icons.repeat), label: 'الجباية الدورية'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long), label: 'وصولاتي'),
        ],
      ),
    );
  }
}
