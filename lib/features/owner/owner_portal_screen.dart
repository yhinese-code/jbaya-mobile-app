import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../finance/cash_tabs.dart';
import '../finance/charts.dart';
import '../finance/fraud_tabs.dart';
import '../finance/overview_tabs.dart';
import '../hr/hr_tabs.dart' show currentPeriod, recentPeriods;
import '../performance/performance_tabs.dart';
import '../shared/ui.dart';

const _ownerColor = Color(0xFF263238);

/// The owner: profit, breakeven, approvals of large write-offs / corrections, and everything finance did.
class OwnerPortalScreen extends StatelessWidget {
  const OwnerPortalScreen({super.key});

  static const _tabs = [
    Tab(icon: Icon(Icons.insights), text: 'الملخص'),
    Tab(icon: Icon(Icons.approval), text: 'الموافقات'),
    Tab(icon: Icon(Icons.savings), text: 'الربح والخسارة'),
    Tab(icon: Icon(Icons.balance), text: 'الأداء والتعادل'),
    Tab(icon: Icon(Icons.today), text: 'التحصيل'),
    Tab(icon: Icon(Icons.menu_book), text: 'كل الحسابات'),
    Tab(icon: Icon(Icons.history_edu), text: 'سجل المالية'),
    Tab(icon: Icon(Icons.gpp_maybe), text: 'كشف التلاعب'),
    Tab(icon: Icon(Icons.trending_up), text: 'التنبؤ'),
    Tab(icon: Icon(Icons.hourglass_bottom), text: 'المتأخرات'),
  ];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text('لوحة المالك - ${Session.instance.fullName}', style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: _ownerColor,
          foregroundColor: Colors.white,
          actions: const [LogoutButton()],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.amber,
            tabs: _tabs,
          ),
        ),
        body: const TabBarView(children: [
          OwnerSummaryTab(),
          ApprovalsTab(),
          ProfitTab(),
          PerformanceMoneyTab(path: '/owner/performance'),
          FinanceOverviewTab(),
          BookTab(),
          FinanceLogTab(),
          FraudTab(),
          ForecastTab(),
          AgingTab(),
        ]),
      ),
    );
  }
}

// ================================================================ summary

class OwnerSummaryTab extends StatelessWidget {
  const OwnerSummaryTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/owner/summary',
      builder: (context, d, reload) {
        final months = (d['months'] as List).cast<Map>().reversed.toList();
        final cur = months.isNotEmpty ? months.last : <String, dynamic>{};
        final cash = d['cash'] as Map;
        final be = d['breakeven'] as Map;
        final alerts = (d['alerts'] as List).cast<String>();
        final sectors = (d['sectors'] as List).cast<Map>();
        final profit = (asNum(cur['profit']) ?? 0).toDouble();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              ...alerts.map((a) => Card(
                    color: Colors.orange.withValues(alpha: 0.08),
                    child: ListTile(dense: true, leading: const Icon(Icons.notification_important, color: Colors.orange), title: Text(a)),
                  )),
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(
                  label: 'ربح هذا الشهر حتى الآن',
                  value: formatIqd(profit),
                  sub: 'دخل ${compactIqd((asNum(cur['income']) ?? 0).toDouble())} - كلف ${compactIqd((asNum(cur['costs']) ?? 0).toDouble())}',
                  icon: Icons.savings,
                  color: profit >= 0 ? Colors.green : Colors.red,
                ),
                KpiCard(
                  label: 'دخل الشركة هذا الشهر',
                  value: formatIqd(asNum(cur['income'])),
                  sub: 'أجور ${compactIqd((asNum(cur['fees']) ?? 0).toDouble())} + حصة ${compactIqd((asNum(cur['share']) ?? 0).toDouble())} (${d['company_share_pct']}%)',
                  icon: Icons.account_balance_wallet,
                  color: Colors.indigo,
                ),
                KpiCard(label: 'نقد الشركة الآن', value: formatIqd(asNum(cash['company_cash'])), sub: 'بعد أمانة الدائرة والضرائب',
                    icon: Icons.account_balance, color: Colors.teal),
                KpiCard(label: 'أمانة دائرة الماء المحفوظة', value: formatIqd(asNum(cash['government_trust'])), icon: Icons.lock, color: Colors.deepOrange),
                KpiCard(label: 'نقد خارج المقر', value: formatIqd(asNum(cash['outside_hq'])), sub: 'لدى الجباة والمشرفين',
                    icon: Icons.directions_walk, color: Colors.brown),
                KpiCard(
                  label: 'نقطة التعادل (وصولات الشهر)',
                  value: '${be['receipts_this_month']} / ${be['receipts_needed_month'] ?? '-'}',
                  sub: be['on_track'] == true ? 'ضمن المسار' : 'متأخرون عن المسار',
                  icon: Icons.flag,
                  color: be['on_track'] == true ? Colors.green : Colors.orange,
                ),
              ]),
              const SectionTitle('آخر 6 أشهر'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    SimpleLineChart(
                      height: 220,
                      labels: months.map((m) => '${m['period']}').toList(),
                      series: [
                        LineSeries('الدخل', months.map((m) => (asNum(m['income']) ?? 0).toDouble()).toList(), Colors.indigo),
                        LineSeries('الكلف', months.map((m) => (asNum(m['costs']) ?? 0).toDouble()).toList(), Colors.orange),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SimpleBarChart(
                      height: 160,
                      labels: months.map((m) => '${m['period']}'.substring(5)).toList(),
                      values: months.map((m) => (asNum(m['profit']) ?? 0).toDouble().abs()).toList(),
                      colors: months.map((m) => (asNum(m['profit']) ?? 0) >= 0 ? Colors.green : Colors.red).toList(),
                      valueName: 'الربح (الأحمر خسارة)',
                    ),
                  ]),
                ),
              ),
              const SectionTitle('القواطع: دخل الشركة هذا الشهر'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: HBarList(
                    color: Colors.indigo,
                    rows: sectors
                        .map((s) => (
                              label: '${s['name']}',
                              value: (asNum(s['income_mtd']) ?? 0).toDouble(),
                              trailing: '${compactIqd((asNum(s['income_mtd']) ?? 0).toDouble())} | ${compactIqd((asNum(s['income_per_property']) ?? 0).toDouble())}/عقار',
                            ))
                        .toList(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('الشطب والتصحيحات فوق ${formatIqd(asNum(d['approval_threshold']))} تنتظر موافقتك.',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ approvals

class ApprovalsTab extends StatefulWidget {
  const ApprovalsTab({super.key});

  @override
  State<ApprovalsTab> createState() => _ApprovalsTabState();
}

class _ApprovalsTabState extends State<ApprovalsTab> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _decide(Map a, String action) async {
    final note = await askNote(context, action == 'approve' ? 'موافقة' : 'رفض', required: action == 'reject');
    if (note == null || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/owner/approvals/${a['kind']}/${a['id']}',
        {'action': action, 'note': note.isEmpty ? null : note}), success: action == 'approve' ? 'تمت الموافقة' : 'تم الرفض');
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/owner/approvals',
      builder: (context, data, reload) {
        final list = (data as List).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (list.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('لا طلبات بانتظار موافقتك'))),
              ...list.map((a) => Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text('${a['title']}', style: const TextStyle(fontWeight: FontWeight.bold))),
                          Text(formatIqd(asNum(a['amount'])), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        ]),
                        if (a['detail'] != null) Text('${a['detail']}', style: const TextStyle(color: Colors.grey)),
                        Text('${formatDate(a['at'])}${a['requested_by'] != null ? ' | طلبه ${a['requested_by']}' : ''}',
                            style: const TextStyle(fontSize: 12, color: Colors.grey)),
                        Wrap(spacing: 8, children: [
                          ElevatedButton(
                            onPressed: () => _decide(a, 'approve'),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                            child: const Text('موافقة'),
                          ),
                          OutlinedButton(
                            onPressed: () => _decide(a, 'reject'),
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                            child: const Text('رفض'),
                          ),
                        ]),
                      ]),
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ profit & loss

class ProfitTab extends StatefulWidget {
  const ProfitTab({super.key});

  @override
  State<ProfitTab> createState() => _ProfitTabState();
}

class _ProfitTabState extends State<ProfitTab> {
  String _period = currentPeriod();

  Widget _line(String label, dynamic amount, {bool bold = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.bold : null))),
          Text(formatIqd(asNum(amount)), style: TextStyle(fontWeight: bold ? FontWeight.bold : null, color: color)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/finance/income-statement?period=$_period',
      builder: (context, d, reload) {
        final income = (d['income'] as List).cast<Map>();
        final costs = (d['costs'] as List).cast<Map>();
        final profit = (asNum(d['profit']) ?? 0).toDouble();
        final trust = d['trust'] as Map;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DropdownButton<String>(
                value: _period,
                items: {...recentPeriods(), _period}.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                onChanged: (v) => setState(() => _period = v ?? _period),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('الربح والخسارة - $_period', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Divider(),
                  const Text('ما دخل للشركة', style: TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
                  if (income.isEmpty) const Text('لا شيء', style: TextStyle(color: Colors.grey)),
                  ...income.map((r) => _line('${r['name']}', r['amount'])),
                  _line('المجموع', d['total_income'], bold: true),
                  const Divider(),
                  const Text('ما صرفته الشركة', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                  if (costs.isEmpty) const Text('لا شيء', style: TextStyle(color: Colors.grey)),
                  ...costs.map((r) => _line('${r['name']}', r['amount'])),
                  _line('المجموع', d['total_costs'], bold: true),
                  const Divider(thickness: 2),
                  _line(profit >= 0 ? 'الربح' : 'الخسارة', profit, bold: true, color: profit >= 0 ? Colors.green : Colors.red),
                ]),
              ),
            ),
            Card(
              color: Colors.deepOrange.withValues(alpha: 0.05),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('أمانة دائرة الماء (ليست ضمن الربح)', style: TextStyle(fontWeight: FontWeight.bold)),
                  _line('حُصّلت هذا الشهر', trust['collected']),
                  _line('سُلّمت هذا الشهر', trust['handed_over']),
                  Text('${trust['note']}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ================================================================ what finance did

class FinanceLogTab extends StatefulWidget {
  const FinanceLogTab({super.key});

  @override
  State<FinanceLogTab> createState() => _FinanceLogTabState();
}

class _FinanceLogTabState extends State<FinanceLogTab> {
  int _days = 7;

  String _amount(Map details) {
    for (final k in const ['amount', 'counted', 'difference']) {
      final v = asNum(details[k]);
      if (v != null) return formatIqd(v);
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('اليوم')),
            ButtonSegment(value: 7, label: Text('7 أيام')),
            ButtonSegment(value: 30, label: Text('30 يوماً')),
          ],
          selected: {_days},
          onSelectionChanged: (s) => setState(() => _days = s.first),
        ),
      ),
      Expanded(
        child: ApiView(
          path: '/owner/finance-log?days=$_days',
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            if (list.isEmpty) return const Center(child: Text('لا إجراءات في هذه الفترة'));
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: list.map((r) {
                  final details = (r['details'] as Map?) ?? {};
                  return Card(
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.history_edu),
                      title: Text('${r['label']} ${_amount(details)}'),
                      subtitle: Text('${r['by']} | ${formatDate(r['at'])} ${formatTime(r['at'])}'
                          '${details['note'] != null ? ' | ${details['note']}' : ''}'),
                    ),
                  );
                }).toList(),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
