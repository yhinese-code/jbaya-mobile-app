import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../collector/widgets/sos_button.dart';
import '../hr/hr_tabs.dart';
import '../performance/performance_tabs.dart';
import '../self_service/self_service_screen.dart' show SelfServiceButton;
import '../shared/alerts_tab.dart';
import '../shared/inbox_button.dart';
import 'deposits_tab.dart';
import 'field_tab.dart';
import 'prev_bills_tab.dart';
import 'reconciliation_tab.dart';
import 'reviews_tab.dart';
import 'team_tab.dart';

/// Supervisor portal: his own field work (same quota as the collectors), team, blind reconciliation,
/// review queues, hand-over to finance, SOS alerts. Tabs follow the tech panel's permission matrix.
class SupervisorScreen extends StatelessWidget {
  const SupervisorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PermittedTabs(
      appBar: (bar) => portalAppBar(
        title: 'بوابة المشرف',
        subtitle: Session.instance.fullName,
        color: AppColors.supervisor,
        actions: const [SosButton(), InboxButton(), SelfServiceButton(), LogoutButton()],
        bottom: bar,
      ),
      tabs: const [
        PortalTab('supervisor.field', Tab(icon: Icon(Icons.directions_walk), text: 'عملي الميداني'), SupervisorFieldTab()),
        PortalTab('supervisor.team', Tab(icon: Icon(Icons.groups), text: 'الفريق'), TeamTab()),
        PortalTab('supervisor.recon', Tab(icon: Icon(Icons.security), text: 'المطابقة النقدية'), ReconciliationTab()),
        PortalTab('supervisor.reviews', Tab(icon: Icon(Icons.rule), text: 'مراجعة الفواتير'), ReviewsTab()),
        PortalTab('supervisor.prev_bills', Tab(icon: Icon(Icons.history_edu), text: 'الفواتير السابقة'), PrevBillsReviewTab()),
        PortalTab('supervisor.handover', Tab(icon: Icon(Icons.business), text: 'التسليم للمالية'), HandToFinanceTab()),
        PortalTab('supervisor.performance', Tab(icon: Icon(Icons.flag), text: 'أداء الفريق'), TeamPerformanceTab()),
        PortalTab('supervisor.sos', Tab(icon: Icon(Icons.sos), text: 'الاستغاثات'), AlertsTab()),
        PortalTab('supervisor.attendance', Tab(icon: Icon(Icons.fingerprint), text: 'حضور الفريق'), AttendanceDayTab()),
        PortalTab('supervisor.leave', Tab(icon: Icon(Icons.beach_access), text: 'إجازات الفريق'), LeaveApprovalsTab(readOnly: true)),
        PortalTab('supervisor.appraisals', Tab(icon: Icon(Icons.star), text: 'تقييم الفريق'), AppraisalsTab()),
      ],
    );
  }
}
