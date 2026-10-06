import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../hr/hr_tabs.dart';
import '../self_service/self_service_screen.dart' show SelfServiceButton;
import 'deposits_verification_tab.dart';
import 'fraud_tabs.dart';
import 'ledger_tabs.dart';
import 'overview_tabs.dart';

/// Finance portal: dashboard, forecasting, fraud analytics (risk, anomalies, Benford), the derived general ledger,
/// deposit verification, government remittances, arrears, payroll release and expense approvals.
class FinancialPortalScreen extends StatelessWidget {
  const FinancialPortalScreen({super.key});

  static const _tabs = [
    Tab(icon: Icon(Icons.dashboard), text: 'نظرة عامة'),
    Tab(icon: Icon(Icons.trending_up), text: 'التنبؤ'),
    Tab(icon: Icon(Icons.gpp_maybe), text: 'المخاطر'),
    Tab(icon: Icon(Icons.warning_amber), text: 'الحالات الشاذة'),
    Tab(icon: Icon(Icons.analytics), text: 'بنفورد'),
    Tab(icon: Icon(Icons.account_balance), text: 'تدقيق الإيداعات'),
    Tab(icon: Icon(Icons.report), text: 'الفروقات المحالة'),
    Tab(icon: Icon(Icons.outbox), text: 'توريد الحكومة'),
    Tab(icon: Icon(Icons.menu_book), text: 'الحسابات'),
    Tab(icon: Icon(Icons.hourglass_bottom), text: 'المتأخرات'),
    Tab(icon: Icon(Icons.payments), text: 'الرواتب'),
    Tab(icon: Icon(Icons.receipt_long), text: 'مصاريف الموظفين'),
  ];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text('البوابة المالية - ${Session.instance.fullName}', style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.green.shade800,
          foregroundColor: Colors.white,
          actions: const [SelfServiceButton(), LogoutButton()],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: _tabs,
          ),
        ),
        body: const TabBarView(children: [
          FinanceOverviewTab(),
          ForecastTab(),
          RiskTab(),
          AnomaliesTab(),
          BenfordTab(),
          DepositsVerificationTab(),
          DifferencesTab(),
          RemittancesTab(),
          AccountsTab(),
          AgingTab(),
          PayrollTab(),
          ExpenseApprovalsTab(),
        ]),
      ),
    );
  }
}
