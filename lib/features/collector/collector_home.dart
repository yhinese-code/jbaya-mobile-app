import 'package:flutter/material.dart';

import '../../core/session.dart';
import 'registration_screen.dart';
import 'route_screen.dart';

/// Field collector app: registration + periodic route. The sector comes from the server (not chosen by the collector).
class CollectorHome extends StatefulWidget {
  const CollectorHome({super.key});

  @override
  State<CollectorHome> createState() => _CollectorHomeState();
}

class _CollectorHomeState extends State<CollectorHome> {
  int _index = 0;
  final _routeKey = GlobalKey<RouteScreenState>();

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
        actions: const [LogoutButton()],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          const RegistrationScreen(),
          RouteScreen(key: _routeKey),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) {
          setState(() => _index = i);
          if (i == 1) _routeKey.currentState?.reload();
        },
        selectedItemColor: const Color(0xFF004D40),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.person_add_alt_1), label: 'تسجيل المواطنين'),
          BottomNavigationBarItem(icon: Icon(Icons.repeat), label: 'الجباية الدورية'),
        ],
      ),
    );
  }
}
