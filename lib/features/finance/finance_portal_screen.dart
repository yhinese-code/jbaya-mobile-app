import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../hr/hr_tabs.dart';
import '../performance/performance_tabs.dart';
import '../self_service/self_service_screen.dart' show SelfServiceButton;
import 'cash_tabs.dart';
import 'fraud_tabs.dart';
import 'overview_tabs.dart';

/// Finance department: receives cash at headquarters, keeps the cash box and the bank, hands the water directorate
/// its trust money, pays salaries. Plain words only. Company profit is not shown here (owner panel).
class FinancialPortalScreen extends StatelessWidget {
  const FinancialPortalScreen({super.key});

  static const _tabs = [
    Tab(icon: Icon(Icons.today), text: 'اليوم'),
    Tab(icon: Icon(Icons.payments), text: 'استلام النقد'),
    Tab(icon: Icon(Icons.point_of_sale), text: 'الصندوق والمصرف'),
    Tab(icon: Icon(Icons.lock), text: 'أمانة دائرة الماء'),
    Tab(icon: Icon(Icons.menu_book), text: 'دفتر الحساب'),
    Tab(icon: Icon(Icons.report), text: 'الفروقات'),
    Tab(icon: Icon(Icons.balance), text: 'الأداء والتعادل'),
    Tab(icon: Icon(Icons.trending_up), text: 'التنبؤ'),
    Tab(icon: Icon(Icons.gpp_maybe), text: 'كشف التلاعب'),
    Tab(icon: Icon(Icons.hourglass_bottom), text: 'المتأخرات'),
    Tab(icon: Icon(Icons.badge), text: 'الرواتب'),
    Tab(icon: Icon(Icons.receipt_long), text: 'مصاريف الموظفين'),
  ];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text('قسم المالية - ${Session.instance.fullName}', style: const TextStyle(fontWeight: FontWeight.bold)),
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
          HandoverTab(),
          CashBoxTab(),
          TrustTab(),
          BookTab(),
          DifferencesTab(),
          PerformanceMoneyTab(),
          ForecastTab(),
          FraudTab(),
          AgingTab(),
          PayrollTab(),
          ExpenseApprovalsTab(),
        ]),
      ),
    );
  }
}
