import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../collector/widgets/sos_button.dart';
import '../shared/alerts_tab.dart';
import 'deposits_tab.dart';
import 'reconciliation_tab.dart';
import 'reviews_tab.dart';
import 'team_tab.dart';

/// Supervisor portal: team, blind reconciliation, review queue, bank deposits, SOS alerts.
class SupervisorScreen extends StatelessWidget {
  const SupervisorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text('بوابة المشرف - ${Session.instance.fullName}', style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.orange.shade800,
          foregroundColor: Colors.white,
          actions: const [SosButton(), LogoutButton()],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [
              Tab(icon: Icon(Icons.groups), text: 'الفريق'),
              Tab(icon: Icon(Icons.security), text: 'المطابقة النقدية'),
              Tab(icon: Icon(Icons.rule), text: 'مراجعة الفواتير'),
              Tab(icon: Icon(Icons.account_balance), text: 'الإيداع المصرفي'),
              Tab(icon: Icon(Icons.sos), text: 'الاستغاثات'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [TeamTab(), ReconciliationTab(), ReviewsTab(), DepositsTab(), AlertsTab()],
        ),
      ),
    );
  }
}
