import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../hr/hr_tabs.dart';
import '../performance/performance_tabs.dart';
import '../self_service/self_service_screen.dart' show SelfServiceButton;
import 'cash_tabs.dart';
import 'fraud_tabs.dart';
import 'gain_share_tab.dart';
import 'overview_tabs.dart';
import 'prev_bills_tab.dart';

/// Finance department: receives cash at headquarters, keeps the cash box and the bank, hands the water directorate
/// its trust money, pays salaries. Plain words only. Company profit is not shown here (owner panel).
/// Each tab follows the tech panel's permission matrix (finance.* features).
class FinancialPortalScreen extends StatelessWidget {
  const FinancialPortalScreen({super.key});

  static const _tabs = [
    PortalTab('finance.today', Tab(icon: Icon(Icons.today), text: 'اليوم'), FinanceOverviewTab()),
    PortalTab('finance.receive', Tab(icon: Icon(Icons.payments), text: 'استلام النقد'), HandoverTab()),
    PortalTab('finance.box', Tab(icon: Icon(Icons.point_of_sale), text: 'الصندوق والمصرف'), CashBoxTab()),
    PortalTab('finance.trust', Tab(icon: Icon(Icons.lock), text: 'أمانة دائرة الماء'), TrustTab()),
    PortalTab('finance.book', Tab(icon: Icon(Icons.menu_book), text: 'دفتر الحساب'), BookTab()),
    PortalTab('finance.differences', Tab(icon: Icon(Icons.report), text: 'الفروقات'), DifferencesTab()),
    PortalTab('finance.performance', Tab(icon: Icon(Icons.balance), text: 'الأداء والتعادل'), PerformanceMoneyTab()),
    PortalTab('finance.gain_share', Tab(icon: Icon(Icons.percent), text: 'صيغة الـ35%'), GainShareTab()),
    PortalTab('finance.prev_bills', Tab(icon: Icon(Icons.history), text: 'الفواتير السابقة'), PrevBillsTab()),
    PortalTab('finance.forecast', Tab(icon: Icon(Icons.trending_up), text: 'التنبؤ'), ForecastTab()),
    PortalTab('finance.fraud', Tab(icon: Icon(Icons.gpp_maybe), text: 'كشف التلاعب'), FraudTab()),
    PortalTab('finance.arrears', Tab(icon: Icon(Icons.hourglass_bottom), text: 'المتأخرات'), AgingTab()),
    PortalTab('finance.payroll', Tab(icon: Icon(Icons.badge), text: 'الرواتب'), PayrollTab()),
    PortalTab('finance.expenses', Tab(icon: Icon(Icons.receipt_long), text: 'مصاريف الموظفين'), ExpenseApprovalsTab()),
  ];

  @override
  Widget build(BuildContext context) {
    return PermittedTabs(
      tabs: _tabs,
      appBar: (bar) => AppBar(
        title: Text('قسم المالية - ${Session.instance.fullName}', style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.green.shade800,
        foregroundColor: Colors.white,
        actions: const [SelfServiceButton(), LogoutButton()],
        bottom: bar,
      ),
    );
  }
}
