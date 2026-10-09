import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../finance/cash_tabs.dart';
import '../finance/charts.dart';
import '../finance/fraud_tabs.dart';
import '../finance/gain_share_tab.dart';
import '../finance/overview_tabs.dart';
import '../hr/hr_tabs.dart' show currentPeriod, recentPeriods;
import '../performance/performance_tabs.dart';
import '../shared/ui.dart';
import 'owner_settings_tab.dart';
import 'owner_today_tab.dart';

/// The owner: his day, profit, breakeven, approvals of large write-offs / corrections / 35% settlements, his own
/// settings, and everything finance did. Each tab follows the tech panel's permission matrix (owner.* features).
class OwnerPortalScreen extends StatelessWidget {
  const OwnerPortalScreen({super.key});

  static const _tabs = [
    PortalTab('owner.summary', Tab(icon: Icon(Icons.wb_sunny), text: 'يومي'), OwnerTodayTab()),
    PortalTab('owner.summary', Tab(icon: Icon(Icons.insights), text: 'الملخص'), OwnerSummaryTab()),
    PortalTab('owner.approvals', Tab(icon: Icon(Icons.approval), text: 'الموافقات'), ApprovalsTab()),
    PortalTab('owner.pnl', Tab(icon: Icon(Icons.savings), text: 'الربح والخسارة'), ProfitTab()),
    PortalTab('owner.performance', Tab(icon: Icon(Icons.balance), text: 'الأداء والتعادل'),
        PerformanceMoneyTab(path: '/owner/performance')),
    PortalTab('owner.gain_share', Tab(icon: Icon(Icons.percent), text: 'صيغة الـ35%'), GainShareTab()),
    PortalTab('owner.collection', Tab(icon: Icon(Icons.today), text: 'التحصيل'), FinanceOverviewTab()),
    PortalTab('owner.accounts', Tab(icon: Icon(Icons.menu_book), text: 'كل الحسابات'), BookTab()),
    PortalTab('owner.finance_log', Tab(icon: Icon(Icons.history_edu), text: 'سجل المالية'), FinanceLogTab()),
    PortalTab('owner.fraud', Tab(icon: Icon(Icons.gpp_maybe), text: 'كشف التلاعب'), FraudTab()),
    PortalTab('owner.forecast', Tab(icon: Icon(Icons.trending_up), text: 'التنبؤ'), ForecastTab()),
    PortalTab('owner.arrears', Tab(icon: Icon(Icons.hourglass_bottom), text: 'المتأخرات'), AgingTab()),
    PortalTab('owner.settings', Tab(icon: Icon(Icons.tune), text: 'إعداداتي'), OwnerSettingsTab()),
  ];

  @override
  Widget build(BuildContext context) {
    return PermittedTabs(
      tabs: _tabs,
      appBar: (bar) => portalAppBar(
        title: 'لوحة المالك',
        subtitle: Session.instance.fullName,
        color: AppColors.owner,
        actions: const [LogoutButton()],
        bottom: bar,
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
            padding: const EdgeInsets.all(Gap.md),
            children: [
              ...alerts.map((a) => NoticeBanner(tone: Tone.warn, icon: Icons.notification_important, title: a)),
              if (alerts.isNotEmpty) const SizedBox(height: Gap.sm),
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(
                  label: 'ربح هذا الشهر حتى الآن',
                  value: formatIqd(profit),
                  sub: 'دخل ${compactIqd((asNum(cur['income']) ?? 0).toDouble())} - كلف ${compactIqd((asNum(cur['costs']) ?? 0).toDouble())}',
                  icon: Icons.savings,
                  color: profit >= 0 ? AppColors.good : AppColors.bad,
                ),
                KpiCard(
                  label: 'دخل الشركة هذا الشهر',
                  value: formatIqd(asNum(cur['income'])),
                  sub: 'أجور ${compactIqd((asNum(cur['fees']) ?? 0).toDouble())} + حصة ${compactIqd((asNum(cur['share']) ?? 0).toDouble())} (${d['company_share_pct']}%)'
                      ' + زيادة ${compactIqd((asNum(cur['gain_share']) ?? 0).toDouble())}',
                  icon: Icons.account_balance_wallet,
                  color: AppColors.brand,
                ),
                KpiCard(label: 'نقد الشركة الآن', value: formatIqd(asNum(cash['company_cash'])), sub: 'بعد أمانة الدائرة والضرائب',
                    icon: Icons.account_balance, color: AppColors.brand),
                KpiCard(label: 'أمانة دائرة الماء المحفوظة', value: formatIqd(asNum(cash['government_trust'])), icon: Icons.lock, color: AppColors.warn),
                KpiCard(label: 'نقد خارج المقر', value: formatIqd(asNum(cash['outside_hq'])), sub: 'لدى الجباة والمشرفين',
                    icon: Icons.directions_walk, color: AppColors.muted),
                KpiCard(
                  label: 'نقطة التعادل (وصولات الشهر)',
                  value: '${be['receipts_this_month']} / ${be['receipts_needed_month'] ?? '-'}',
                  sub: be['on_track'] == true ? 'ضمن المسار' : 'متأخرون عن المسار',
                  icon: Icons.flag,
                  color: be['on_track'] == true ? AppColors.good : AppColors.warn,
                ),
              ]),
              const SectionTitle('آخر 6 أشهر'),
              AppCard(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(children: [
                    SimpleLineChart(
                      height: 220,
                      labels: months.map((m) => '${m['period']}').toList(),
                      series: [
                        LineSeries('الدخل', months.map((m) => (asNum(m['income']) ?? 0).toDouble()).toList(), AppColors.brand),
                        LineSeries('الكلف', months.map((m) => (asNum(m['costs']) ?? 0).toDouble()).toList(), AppColors.warn),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SimpleBarChart(
                      height: 160,
                      labels: months.map((m) => '${m['period']}'.substring(5)).toList(),
                      values: months.map((m) => (asNum(m['profit']) ?? 0).toDouble().abs()).toList(),
                      colors: months.map((m) => (asNum(m['profit']) ?? 0) >= 0 ? AppColors.good : AppColors.bad).toList(),
                      valueName: 'الربح (الأحمر خسارة)',
                    ),
                  ]),
              ),
              const SectionTitle('دخل الشركة حسب المصدر'),
              Card(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(AppColors.paper),
                    headingTextStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontWeight: FontWeight.w600, color: AppColors.muted, fontSize: 13),
                    dataTextStyle: const TextStyle(fontFamily: AppTheme.fontFamily, color: AppColors.ink, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
                    columnSpacing: 20,
                    headingRowHeight: 40,
                    dataRowMinHeight: 36,
                    dataRowMaxHeight: 40,
                    columns: const [
                      DataColumn(label: Text('الشهر')),
                      DataColumn(label: Text('أجور الجباية'), numeric: true),
                      DataColumn(label: Text('الحصة'), numeric: true),
                      DataColumn(label: Text('حصة الزيادة (35%)'), numeric: true),
                      DataColumn(label: Text('مجموع الدخل'), numeric: true),
                      DataColumn(label: Text('الربح'), numeric: true),
                    ],
                    rows: [
                      for (final m in months.reversed)
                        DataRow(cells: [
                          DataCell(Text('${m['period']}')),
                          DataCell(Text(compactIqd((asNum(m['fees']) ?? 0).toDouble()))),
                          DataCell(Text(compactIqd((asNum(m['share']) ?? 0).toDouble()))),
                          DataCell(Text(compactIqd((asNum(m['gain_share']) ?? 0).toDouble()),
                              style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.bold))),
                          DataCell(Text(compactIqd((asNum(m['income']) ?? 0).toDouble()))),
                          DataCell(Text(compactIqd((asNum(m['profit']) ?? 0).toDouble()),
                              style: TextStyle(color: (asNum(m['profit']) ?? 0) >= 0 ? AppColors.good : AppColors.bad))),
                        ]),
                    ],
                  ),
                ),
              ),
              const SectionTitle('القواطع: دخل الشركة هذا الشهر'),
              AppCard(
                padding: const EdgeInsets.all(Gap.md),
                child: HBarList(
                    color: AppColors.brand,
                    rows: sectors
                        .map((s) => (
                              label: '${s['name']}',
                              value: (asNum(s['income_mtd']) ?? 0).toDouble(),
                              trailing: '${compactIqd((asNum(s['income_mtd']) ?? 0).toDouble())} | ${compactIqd((asNum(s['income_per_property']) ?? 0).toDouble())}/عقار',
                            ))
                        .toList(),
                  ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('الشطب والتصحيحات فوق ${formatIqd(asNum(d['approval_threshold']))} تنتظر موافقتك.',
                    style: const TextStyle(color: AppColors.muted, fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ approvals

const Map<String, String> _kindLabels = {
  'journal': 'تصحيح يدوي',
  'reconciliation': 'شطب جابي',
  'handover': 'شطب مشرف',
  'gain_share': 'تسوية صيغة الـ35%',
};

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
            padding: const EdgeInsets.all(Gap.md),
            children: [
              if (list.isEmpty) const EmptyState(icon: Icons.task_alt, title: 'لا طلبات بانتظار موافقتك', message: 'الشطب والتصحيحات الكبيرة التي تحتاج موافقتك ستظهر هنا'),
              ...list.map((a) => AppCard(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          StatusChip(_kindLabels['${a['kind']}'] ?? '${a['kind']}',
                              a['kind'] == 'gain_share' ? AppColors.info : AppColors.muted),
                          const Spacer(),
                          Text(formatIqd(asNum(a['amount'])),
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, fontFeatures: [FontFeature.tabularFigures()])),
                        ]),
                        const SizedBox(height: Gap.xs),
                        Text('${a['title'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        if (a['detail'] != null) Text('${a['detail']}', style: const TextStyle(color: AppColors.muted)),
                        if (a['kind'] == 'gain_share')
                          const Text('موافقتك تقيّد هذا المبلغ دخلاً للشركة (حصة الزيادة فوق إيرادات 2025).',
                              style: TextStyle(fontSize: 12, color: AppColors.brand)),
                        Text('${formatDate(a['at'])}${a['requested_by'] != null ? ' | طلبه ${a['requested_by']}' : ''}',
                            style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                        const SizedBox(height: Gap.sm),
                        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                          ElevatedButton(
                            onPressed: () => _decide(a, 'approve'),
                            style: ElevatedButton.styleFrom(backgroundColor: AppColors.good, foregroundColor: Colors.white),
                            child: const Text('موافقة'),
                          ),
                          OutlinedButton(
                            onPressed: () => _decide(a, 'reject'),
                            style: OutlinedButton.styleFrom(foregroundColor: AppColors.bad),
                            child: const Text('رفض'),
                          ),
                        ]),
                      ]),
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
          Text(formatIqd(asNum(amount)),
              textAlign: TextAlign.end,
              style: TextStyle(fontWeight: bold ? FontWeight.bold : null, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
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
          padding: const EdgeInsets.all(Gap.md),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DropdownButton<String>(
                value: _period,
                items: {...recentPeriods(), _period}.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                onChanged: (v) => setState(() => _period = v ?? _period),
              ),
            ),
            AppCard(
              padding: const EdgeInsets.all(Gap.lg),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('الربح والخسارة - $_period', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Divider(),
                  const Text('ما دخل للشركة', style: TextStyle(color: AppColors.brand, fontWeight: FontWeight.bold)),
                  if (income.isEmpty) const Text('لا شيء', style: TextStyle(color: AppColors.muted)),
                  ...income.map((r) => _line('${r['name']}', r['amount'])),
                  _line('المجموع', d['total_income'], bold: true),
                  const Divider(),
                  const Text('ما صرفته الشركة', style: TextStyle(color: AppColors.bad, fontWeight: FontWeight.bold)),
                  if (costs.isEmpty) const Text('لا شيء', style: TextStyle(color: AppColors.muted)),
                  ...costs.map((r) => _line('${r['name']}', r['amount'])),
                  _line('المجموع', d['total_costs'], bold: true),
                  const Divider(thickness: 2),
                  _line(profit >= 0 ? 'الربح' : 'الخسارة', profit, bold: true, color: profit >= 0 ? AppColors.good : AppColors.bad),
                ]),
            ),
            AppCard(
              accent: AppColors.warn,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('أمانة دائرة الماء (ليست ضمن الربح)', style: TextStyle(fontWeight: FontWeight.bold)),
                  _line('حُصّلت هذا الشهر', trust['collected']),
                  _line('سُلّمت هذا الشهر', trust['handed_over']),
                  Text('${trust['note']}', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                ]),
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
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
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
            if (list.isEmpty) return const EmptyState(icon: Icons.history_edu, title: 'لا إجراءات للمالية في هذه الفترة', message: 'جرّب فترة أطول');
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.all(Gap.md),
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
