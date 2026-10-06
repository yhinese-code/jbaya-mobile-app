import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../finance/charts.dart';
import '../hr/hr_tabs.dart' show currentPeriod, recentPeriods;
import '../shared/ui.dart';

const _statusColors = {
  'profitable': Color(0xFF2E7D32),
  'losing': Color(0xFFC62828),
  'leave': Color(0xFF1565C0),
  'today': Color(0xFF9E9E9E),
  'extra': Color(0xFF00897B),
};
const _statusLabels = {
  'profitable': 'غطّى كلفته',
  'losing': 'لم يغطِّ كلفته',
  'leave': 'إجازة',
  'today': 'اليوم (جارٍ)',
  'extra': 'عطلة بعمل إضافي',
};

/// A row of small day squares (green = covered his cost, red = didn't, blue = leave).
class DayStrip extends StatelessWidget {
  final List<Map> days;
  const DayStrip({super.key, required this.days});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      children: days.map((d) {
        final c = _statusColors[d['status']] ?? Colors.grey;
        return Tooltip(
          message: '${d['day']}: ${_statusLabels[d['status']] ?? d['status']} | ${d['receipts']} وصل',
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(color: c.withValues(alpha: d['status'] == 'today' ? 0.35 : 0.85), borderRadius: BorderRadius.circular(3)),
            alignment: Alignment.center,
            child: Text('${d['receipts']}', style: const TextStyle(fontSize: 8, color: Colors.white)),
          ),
        );
      }).toList(),
    );
  }
}

Widget _legend() => Wrap(spacing: 12, runSpacing: 4, children: [
      for (final k in const ['profitable', 'losing', 'leave', 'today'])
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 12, height: 12, color: _statusColors[k]),
          const SizedBox(width: 4),
          Text(_statusLabels[k]!, style: const TextStyle(fontSize: 12)),
        ]),
    ]);

// ================================================================ money view (owner, finance, command)

class PerformanceMoneyTab extends StatefulWidget {
  /// '/performance/collectors' for finance/command, '/owner/performance' for the owner (adds the company breakeven).
  final String path;
  const PerformanceMoneyTab({super.key, this.path = '/performance/collectors'});

  @override
  State<PerformanceMoneyTab> createState() => _PerformanceMoneyTabState();
}

class _PerformanceMoneyTabState extends State<PerformanceMoneyTab> {
  String _period = currentPeriod();

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Row(children: [
          DropdownButton<String>(
            value: _period,
            items: {...recentPeriods(), _period}.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
            onChanged: (v) => setState(() => _period = v ?? _period),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('كلفة الجابي اليومية = (الراتب + المخصصات) ÷ أيام العمل + عمولته. ما تكسبه الشركة منه = أجور الخدمة + حصتها من مبالغ الماء.',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ]),
      ),
      Expanded(
        child: ApiView(
          path: '${widget.path}?period=$_period',
          builder: (context, d, reload) {
            final rows = (d['collectors'] as List).cast<Map>();
            final t = d['totals'] as Map;
            final company = d['company'] as Map?;
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    KpiCard(label: 'ما كسبته الشركة من الجباة', value: formatIqd(asNum(t['earnings'])), icon: Icons.trending_up, color: Colors.green),
                    KpiCard(label: 'كلفة الجباة (رواتب وعمولات)', value: formatIqd(asNum(t['cost'])), icon: Icons.payments, color: Colors.orange),
                    KpiCard(
                      label: 'الفرق',
                      value: formatIqd(asNum(t['net'])),
                      icon: Icons.balance,
                      color: (asNum(t['net']) ?? 0) >= 0 ? Colors.teal : Colors.red,
                    ),
                    KpiCard(
                      label: 'جباة متقاعسون',
                      value: '${t['flagged']}',
                      sub: '${d['streak_alert_days']} أيام متتالية أو أكثر دون تغطية الكلفة',
                      icon: Icons.flag,
                      color: (asNum(t['flagged']) ?? 0) > 0 ? Colors.red : Colors.green,
                    ),
                    KpiCard(label: 'معدل الفريق اليومي', value: '${d['team_avg_receipts_per_day']} وصل', icon: Icons.groups, color: Colors.blueGrey),
                  ]),
                  if (company != null) ...[
                    const SectionTitle('نقطة التعادل للشركة (هذا الشهر)'),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('رواتب ومخصصات ${company['staff']} موظفاً: ${formatIqd(asNum(company['monthly_staff_cost']))} شهرياً'),
                          Text('تكسب الشركة بالمتوسط ${formatIqd(asNum(company['net_per_receipt']))} صافياً من كل وصل'),
                          Text('تحتاج ${company['receipts_needed_month']} وصل هذا الشهر (${company['receipts_needed_per_working_day']} في يوم العمل) لتغطية الرواتب',
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: (asNum(company['receipts_needed_month']) ?? 0) > 0
                                ? ((asNum(company['receipts_this_month']) ?? 0) / (asNum(company['receipts_needed_month']) ?? 1)).clamp(0.0, 1.0).toDouble()
                                : 0,
                            minHeight: 10,
                            color: company['on_track'] == true ? Colors.green : Colors.orange,
                          ),
                          const SizedBox(height: 4),
                          Text('حتى الآن ${company['receipts_this_month']} وصلاً بعد ${company['working_days_done']} من ${company['working_days']} يوم عمل '
                              '— ${company['on_track'] == true ? 'ضمن المسار' : 'متأخرون عن المسار'}',
                              style: TextStyle(color: company['on_track'] == true ? Colors.green : Colors.orange)),
                        ]),
                      ),
                    ),
                  ],
                  const SectionTitle('الجباة: من يغطي كلفته؟'),
                  _legend(),
                  const SizedBox(height: 8),
                  ...rows.map((c) {
                    final net = (asNum(c['net']) ?? 0).toDouble();
                    final flag = c['lazy_flag'] == true;
                    return Card(
                      color: flag ? Colors.red.withValues(alpha: 0.05) : null,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            if (flag) const Padding(padding: EdgeInsetsDirectional.only(end: 6), child: Icon(Icons.flag, color: Colors.red)),
                            Expanded(child: Text('${c['employee_code']} - ${c['full_name']}', style: const TextStyle(fontWeight: FontWeight.bold))),
                            StatusChip('${c['label']}', flag ? Colors.red : (net >= 0 ? Colors.green : Colors.orange)),
                          ]),
                          const SizedBox(height: 6),
                          Wrap(spacing: 14, runSpacing: 4, children: [
                            Text('كسبت الشركة منه: ${formatIqd(asNum(c['earnings']))}'),
                            Text('كلفته: ${formatIqd(asNum(c['cost']))}'),
                            Text('الفرق: ${formatIqd(net)}', style: TextStyle(fontWeight: FontWeight.bold, color: net >= 0 ? Colors.green : Colors.red)),
                            Text('كلفته اليومية: ${formatIqd(asNum(c['daily_fixed_cost']))}'),
                            Text('هدف التعادل: ${c['breakeven_receipts_per_day'] ?? '-'} وصل/يوم'),
                            Text('معدله: ${c['receipts_per_day'] ?? '-'} وصل/يوم'),
                            Text('أيام غطّى فيها كلفته ${c['profitable_days']} | لم يغطِّ ${c['losing_days']}'),
                            if ((asNum(c['losing_streak']) ?? 0) > 0)
                              Text('متتالية: ${c['losing_streak']}', style: const TextStyle(color: Colors.red)),
                          ]),
                          const SizedBox(height: 8),
                          DayStrip(days: (c['days'] as List).cast<Map>()),
                        ]),
                      ),
                    );
                  }),
                ],
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ================================================================ supervisor: houses, never money

class TeamPerformanceTab extends StatelessWidget {
  const TeamPerformanceTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/supervisor/performance',
      builder: (context, d, reload) {
        final rows = (d['collectors'] as List).cast<Map>();
        final laggards = (asNum(d['laggards']) ?? 0).toInt();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (laggards > 0)
                Card(
                  color: Colors.red.withValues(alpha: 0.08),
                  child: ListTile(
                    leading: const Icon(Icons.flag, color: Colors.red),
                    title: Text(laggards == 1 ? 'لديك موظف متأخر يحتاج متابعة' : 'لديك $laggards موظفين متأخرين يحتاجون متابعة'),
                    subtitle: const Text('لم يحققوا هدفهم اليومي لعدة أيام متتالية'),
                  ),
                ),
              Text('معدل الفريق: ${d['team_avg_receipts_per_day']} منزل في اليوم', style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 6),
              _legend(),
              const SizedBox(height: 8),
              if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('لا يوجد جباة في فريقك'))),
              ...rows.map((c) {
                final target = (asNum(c['daily_target']) ?? 0).toInt();
                final today = (asNum(c['today_receipts']) ?? 0).toInt();
                final flag = c['flag'] == true;
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text('${c['employee_code']} - ${c['full_name']}', style: const TextStyle(fontWeight: FontWeight.bold))),
                        StatusChip('${c['label']}', flag ? Colors.red : (c['label'] == 'ضمن الهدف' ? Colors.green : Colors.orange)),
                      ]),
                      const SizedBox(height: 6),
                      Text('اليوم: $today من ${housesAr(target)}${(asNum(c['remaining_today']) ?? 0) > 0 ? ' — يحتاج ${housesAr((asNum(c['remaining_today']) ?? 0).toInt())} أخرى' : ' — حقق الهدف'}'),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: target > 0 ? (today / target).clamp(0.0, 1.0).toDouble() : 0,
                        minHeight: 8,
                        color: today >= target ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(height: 6),
                      Text('معدله هذا الشهر ${c['receipts_per_day'] ?? '-'} منزل/يوم | أيام جيدة ${c['good_days']} | أيام ضعيفة ${c['weak_days']}',
                          style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      const SizedBox(height: 6),
                      DayStrip(days: (c['days'] as List).cast<Map>()),
                    ]),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ collector: his own coaching card

class CoachCard extends StatefulWidget {
  const CoachCard({super.key});

  @override
  State<CoachCard> createState() => CoachCardState();
}

class CoachCardState extends State<CoachCard> {
  Map? _c;
  bool _open = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final c = await ApiClient.instance.get('/collector/coach');
      if (mounted) setState(() => _c = c as Map);
    } on ApiException catch (_) {
      // informational only
    }
  }

  static const _levelColors = {'good': Colors.green, 'info': Colors.blue, 'warn': Colors.orange, 'bad': Colors.red};

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || c['daily_target'] == null) return const SizedBox.shrink();
    final target = (asNum(c['daily_target']) ?? 0).toInt();
    final today = (asNum(c['today_receipts']) ?? 0).toInt();
    final msgs = (c['messages'] as List).cast<Map>();
    final worst = msgs.any((m) => m['level'] == 'bad') ? 'bad' : (msgs.any((m) => m['level'] == 'warn') ? 'warn' : (today >= target ? 'good' : 'info'));
    final color = _levelColors[worst] ?? Colors.blue;
    return Material(
      color: color.withValues(alpha: 0.07),
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.flag_circle, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text('هدفك اليوم: $today من ${housesAr(target)}', style: TextStyle(fontWeight: FontWeight.bold, color: color))),
              Text('معدل الفريق ${c['team_avg']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Icon(_open ? Icons.expand_less : Icons.expand_more, color: Colors.grey),
            ]),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: target > 0 ? (today / target).clamp(0.0, 1.0).toDouble() : 0, minHeight: 6, color: color),
            if (_open)
              ...msgs.map((m) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('• ${m['text']}', style: TextStyle(color: _levelColors[m['level']] ?? Colors.black87, fontSize: 13)),
                  )),
          ]),
        ),
      ),
    );
  }
}
