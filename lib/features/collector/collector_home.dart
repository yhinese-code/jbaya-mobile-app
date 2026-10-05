import 'package:flutter/material.dart';

import '../../core/session.dart';
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

  void _refreshAll() {
    _summaryKey.currentState?.reload();
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
          SosButton(onSent: () => _summaryKey.currentState?.reload()),
          IconButton(tooltip: 'تحديث', icon: const Icon(Icons.refresh), onPressed: _refreshAll),
          const LogoutButton(),
        ],
      ),
      body: Column(
        children: [
          SummaryBar(key: _summaryKey),
          const Divider(height: 1),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                RegistrationScreen(onCollected: () => _summaryKey.currentState?.reload()),
                RouteScreen(key: _routeKey, onCollected: () => _summaryKey.currentState?.reload()),
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
