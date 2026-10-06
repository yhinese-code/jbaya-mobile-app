import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../collector/widgets/sos_button.dart';
import '../hr/hr_tabs.dart';
import '../performance/performance_tabs.dart';
import '../self_service/self_service_screen.dart' show SelfServiceButton;
import '../shared/alerts_tab.dart';
import '../shared/inbox_button.dart';
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
      length: 9,
      child: Scaffold(
        appBar: AppBar(
          title: Text('بوابة المشرف - ${Session.instance.fullName}', style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.orange.shade800,
          foregroundColor: Colors.white,
          actions: const [SosButton(), InboxButton(), SelfServiceButton(), LogoutButton()],
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
              Tab(icon: Icon(Icons.business), text: 'التسليم للمالية'),
              Tab(icon: Icon(Icons.flag), text: 'أداء الفريق'),
              Tab(icon: Icon(Icons.sos), text: 'الاستغاثات'),
              Tab(icon: Icon(Icons.fingerprint), text: 'حضور الفريق'),
              Tab(icon: Icon(Icons.beach_access), text: 'طلبات الإجازة'),
              Tab(icon: Icon(Icons.star), text: 'تقييم الفريق'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [TeamTab(), ReconciliationTab(), ReviewsTab(), HandToFinanceTab(), TeamPerformanceTab(), AlertsTab(), AttendanceDayTab(), LeaveApprovalsTab(), AppraisalsTab()],
        ),
      ),
    );
  }
}
