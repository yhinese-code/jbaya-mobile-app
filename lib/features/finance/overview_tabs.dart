import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../shared/ui.dart';
import 'charts.dart';

// ================================================================ overview

class FinanceOverviewTab extends StatefulWidget {
  const FinanceOverviewTab({super.key});

  @override
  State<FinanceOverviewTab> createState() => _FinanceOverviewTabState();
}

class _FinanceOverviewTabState extends State<FinanceOverviewTab> {
  int _days = 30;

  String _change(dynamic v) {
    final n = asNum(v);
    if (n == null) return 'لا مقارنة';
    final up = n >= 0;
    return '${up ? '▲' : '▼'} ${(n.abs() * 100).toStringAsFixed(1)}% عن نفس الفترة من الشهر السابق';
  }

  Widget _cashStep(String label, dynamic value, Color color, {bool arrow = true}) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 170,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(formatIqd(asNum(value)), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        ]),
      ),
      if (arrow) const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.arrow_forward, color: AppColors.muted)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/finance/overview?days=$_days',
      builder: (context, d, reload) {
        final k = d['kpis'] as Map;
        final cash = d['cash'] as Map;
        final today = k['today'] as Map, mtd = k['mtd'] as Map, y = k['yesterday'] as Map;
        final series = (d['series'] as List).cast<Map>();
        final sectors = (d['sectors'] as List).cast<Map>();
        final classes = (d['classes'] as List).cast<Map>();
        final cols = (d['collectors'] as List).cast<Map>();
        final suspense = (asNum(cash['differences']) ?? 0).toDouble();
        final profit = d['profit_mtd'] as Map?;
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(
                  label: 'تحصيل اليوم',
                  value: formatIqd(asNum(today['total'])),
                  sub: 'أمس ${compactIqd((asNum(y['total']) ?? 0).toDouble())} | ${today['count']} وصل',
                  icon: Icons.today,
                  color: AppColors.brand,
                ),
                KpiCard(
                  label: 'تحصيل الشهر حتى اليوم',
                  value: formatIqd(asNum(mtd['total'])),
                  sub: _change(k['mtd_change']),
                  icon: Icons.calendar_month,
                  color: (asNum(k['mtd_change']) ?? 0) >= 0 ? AppColors.good : AppColors.bad,
                ),
                KpiCard(
                  label: 'دخل الشركة هذا الشهر',
                  value: formatIqd(asNum(k['company_income_mtd'])),
                  sub: 'أجور الخدمة + حصة الشركة من مبالغ الماء',
                  icon: Icons.account_balance_wallet,
                  color: AppColors.brand,
                ),
                KpiCard(
                  label: 'أمانة دائرة الماء هذا الشهر',
                  value: formatIqd(asNum(k['trust_mtd'])),
                  sub: 'ليست دخلاً للشركة',
                  icon: Icons.lock,
                  color: AppColors.warn,
                ),
                if (profit != null)
                  KpiCard(
                    label: 'ربح الشركة هذا الشهر (للمالك)',
                    value: formatIqd(asNum(profit['profit'])),
                    sub: 'دخل ${compactIqd((asNum(profit['income']) ?? 0).toDouble())} - كلف ${compactIqd((asNum(profit['costs']) ?? 0).toDouble())}',
                    icon: Icons.savings,
                    color: (asNum(profit['profit']) ?? 0) >= 0 ? AppColors.good : AppColors.bad,
                  ),
                KpiCard(
                  label: 'متوسط الوصل',
                  value: formatIqd(asNum(mtd['avg_ticket'])),
                  sub: '${mtd['count']} وصل هذا الشهر',
                  icon: Icons.receipt,
                  color: AppColors.muted,
                ),
                KpiCard(
                  label: 'تغطية العقارات (30 يوم)',
                  value: pctText(k['coverage_30d']),
                  sub: '${k['active_properties']} عقار فعال${(asNum(k['pending_properties']) ?? 0) > 0 ? ' | ${k['pending_properties']} بانتظار التأكيد' : ''}',
                  icon: Icons.home_work,
                  color: AppColors.muted,
                ),
                KpiCard(
                  label: 'موثق برمز المواطن',
                  value: pctText(mtd['otp_share']),
                  sub: 'الباقي بالرمز الرئيسي',
                  icon: Icons.verified_user,
                  color: (asNum(mtd['otp_share']) ?? 1) >= 0.9 ? AppColors.good : AppColors.warn,
                ),
                KpiCard(
                  label: 'فواتير بالتقدير',
                  value: pctText(k['estimate_share_mtd']),
                  sub: 'عليها ملاحظات ${pctText(k['flagged_share_mtd'])}',
                  icon: Icons.speed,
                  color: AppColors.warn,
                ),
              ]),
              const SectionTitle('أين النقد الآن'),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _cashStep('لدى الجباة', cash['with_collectors'], AppColors.warn),
                  _cashStep('لدى المشرفين', cash['with_supervisors'], AppColors.warn),
                  _cashStep('صندوق المالية', cash['cash_box'], AppColors.info),
                  _cashStep('المصرف', cash['bank'], AppColors.good, arrow: false),
                ]),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                Chip(
                  avatar: const Icon(Icons.lock, size: 18),
                  label: Text('أمانة دائرة الماء المحفوظة: ${formatIqd(asNum(cash['government_trust']))}'),
                ),
                Chip(label: Text('نقد الشركة (بعد الأمانة والضرائب): ${formatIqd(asNum(cash['company_cash']))}')),
                Chip(label: Text('نقد لم يصل المقر بعد: ${formatIqd(asNum(cash['outside_hq']))}')),
                if (suspense != 0)
                  Chip(
                    backgroundColor: AppColors.bad.withValues(alpha: 0.08),
                    avatar: const Icon(Icons.warning, color: AppColors.bad, size: 18),
                    label: Text('فروقات معلقة قيد التحقيق: ${formatIqd(suspense)}'),
                  ),
                if ((asNum(cash['employees_owe']) ?? 0) != 0)
                  Chip(label: Text('نقص يُخصم من الرواتب: ${formatIqd(asNum(cash['employees_owe']))}')),
              ]),
              SectionTitle('التحصيل اليومي', actions: [
                SegmentedButton<int>(
                  segments: const [ButtonSegment(value: 30, label: Text('30')), ButtonSegment(value: 60, label: Text('60')), ButtonSegment(value: 90, label: Text('90'))],
                  selected: {_days},
                  onSelectionChanged: (s) => setState(() => _days = s.first),
                ),
              ]),
              AppCard(
                padding: const EdgeInsets.all(Gap.md),
                child: SimpleLineChart(
                    labels: series.map((s) => shortDay('${s['day']}')).toList(),
                    series: [
                      LineSeries('المحصل', series.map((s) => (asNum(s['total']) ?? 0).toDouble()).toList(), AppColors.brand, fill: true),
                      LineSeries('دخل الشركة', series.map((s) => (asNum(s['company_income']) ?? 0).toDouble()).toList(), ChartColors.secondary, width: 1.5),
                      LineSeries('أمانة الدائرة', series.map((s) => (asNum(s['trust']) ?? 0).toDouble()).toList(), ChartColors.tertiary, width: 1.5),
                    ],
                  ),
              ),
              LayoutBuilder(builder: (context, c) {
                final sectorCard = AppCard(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('القواطع (هذا الشهر)', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      if (sectors.isEmpty) const EmptyState(title: 'لا توجد جباية مسجلة هذا الشهر'),
                      HBarList(
                        rows: sectors
                            .map((s) => (
                                  label: '${s['name']}',
                                  value: (asNum(s['collected']) ?? 0).toDouble(),
                                  trailing: '${compactIqd((asNum(s['collected']) ?? 0).toDouble())} | تغطية ${pctText(s['coverage'])}',
                                ))
                            .toList(),
                      ),
                    ]),
                );
                final classCard = AppCard(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('حسب فئة العقار (هذا الشهر)', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      if (classes.isEmpty) const EmptyState(title: 'لا توجد جباية مسجلة هذا الشهر'),
                      HBarList(
                        color: ChartColors.secondary,
                        rows: classes
                            .map((s) => (
                                  label: propertyClassLabels[s['property_class']] ?? '${s['property_class']}',
                                  value: (asNum(s['collected']) ?? 0).toDouble(),
                                  trailing: '${compactIqd((asNum(s['collected']) ?? 0).toDouble())} | ${s['receipts']} وصل',
                                ))
                            .toList(),
                      ),
                    ]),
                );
                if (c.maxWidth >= 900) {
                  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: sectorCard), Expanded(child: classCard)]);
                }
                return Column(children: [sectorCard, classCard]);
              }),
              const SectionTitle('الجباة (هذا الشهر)'),
              if (cols.isEmpty) const EmptyState(icon: Icons.groups_outlined, title: 'لا توجد جباية للجباة هذا الشهر'),
              if (cols.isNotEmpty)
              Card(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(AppColors.paper),
                    headingTextStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontWeight: FontWeight.w600, color: AppColors.muted, fontSize: 13),
                    dataTextStyle: const TextStyle(fontFamily: AppTheme.fontFamily, color: AppColors.ink, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
                    columns: const [
                      DataColumn(label: Text('الجابي')),
                      DataColumn(label: Text('المحصل'), numeric: true),
                      DataColumn(label: Text('الوصولات'), numeric: true),
                      DataColumn(label: Text('متوسط الوصل'), numeric: true),
                      DataColumn(label: Text('الرمز الرئيسي'), numeric: true),
                    ],
                    rows: cols
                        .map((c) => DataRow(cells: [
                              DataCell(Text('${c['employee_code']} - ${c['full_name']}')),
                              DataCell(Text(formatIqd(asNum(c['collected'])))),
                              DataCell(Text('${c['receipts']}')),
                              DataCell(Text(formatIqd(asNum(c['avg_ticket'])))),
                              DataCell(Text('${c['master_uses']}',
                                  style: TextStyle(color: (asNum(c['master_uses']) ?? 0) > 0 ? AppColors.warn : null))),
                            ]))
                        .toList(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ forecast

class ForecastTab extends StatelessWidget {
  const ForecastTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/finance/forecast?horizon=30',
      builder: (context, d, reload) {
        if (d['available'] != true) {
          return EmptyState(icon: Icons.insights, title: 'التنبؤ غير متاح بعد', message: '${d['message']}');
        }
        final hist = (d['history'] as List).cast<Map>();
        final fc = (d['forecast'] as List).cast<Map>();
        final month = d['month'] as Map;
        final prof = (d['weekday_profile'] as List).cast<Map>();
        final n = hist.length + fc.length;
        final labels = [...hist.map((h) => shortDay('${h['day']}')), ...fc.map((f) => shortDay('${f['day']}'))];
        final actual = <double?>[...hist.map((h) => (asNum(h['value']) ?? 0).toDouble()), ...List<double?>.filled(fc.length, null)];
        final predicted = <double?>[
          ...List<double?>.filled(hist.isEmpty ? 0 : hist.length - 1, null),
          if (hist.isNotEmpty) (asNum(hist.last['value']) ?? 0).toDouble(),
          ...fc.map((f) => (asNum(f['value']) ?? 0).toDouble()),
        ];
        final lower = <double?>[...List<double?>.filled(hist.length, null), ...fc.map((f) => (asNum(f['lower']) ?? 0).toDouble())];
        final upper = <double?>[...List<double?>.filled(hist.length, null), ...fc.map((f) => (asNum(f['upper']) ?? 0).toDouble())];
        final mape = asNum(d['mape']);
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              if (d['warning'] != null) NoticeBanner(tone: Tone.warn, title: '${d['warning']}'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(
                  label: 'المتوقع لنهاية الشهر',
                  value: formatIqd(asNum(month['projected_total'])),
                  sub: 'بين ${compactIqd((asNum(month['projected_low']) ?? 0).toDouble())} و ${compactIqd((asNum(month['projected_high']) ?? 0).toDouble())}',
                  icon: Icons.flag,
                  color: AppColors.brand,
                ),
                KpiCard(label: 'المحصل حتى أمس', value: formatIqd(asNum(month['actual_to_yesterday'])), icon: Icons.check_circle, color: AppColors.good),
                KpiCard(label: 'اليوم حتى الآن', value: formatIqd(asNum(d['today_so_far'])), icon: Icons.today, color: AppColors.brand),
                KpiCard(label: 'المتوقع خلال 30 يوماً', value: formatIqd(asNum(d['next_30_days'])), icon: Icons.trending_up, color: AppColors.info),
                KpiCard(
                  label: 'دقة النموذج',
                  value: mape == null ? '-' : '${((1 - mape) * 100).clamp(0, 100).toStringAsFixed(0)}%',
                  sub: d['method'] == 'holt_winters' ? 'هولت-وينترز بموسمية أسبوعية | ${d['history_days']} يوم' : 'متوسط بسيط (بيانات قليلة)',
                  icon: Icons.insights,
                  color: AppColors.muted,
                ),
              ]),
              const SectionTitle('الفعلي والمتوقع'),
              AppCard(
                padding: const EdgeInsets.all(Gap.md),
                child: SimpleLineChart(
                    height: 280,
                    labels: labels,
                    markerIndex: hist.length < n ? hist.length : null,
                    band: ChartBand(lower, upper, ChartColors.secondary.withValues(alpha: 0.12)),
                    series: [
                      LineSeries('الفعلي', actual, AppColors.brand, fill: true),
                      LineSeries('المتوقع', predicted, ChartColors.secondary, dashed: true),
                    ],
                  ),
              ),
              const SectionTitle('متوسط التحصيل حسب يوم الأسبوع'),
              AppCard(
                padding: const EdgeInsets.all(Gap.md),
                child: SimpleBarChart(
                    labels: prof.map((p) => '${p['label']}').toList(),
                    values: prof.map((p) => (asNum(p['avg']) ?? 0).toDouble()).toList(),
                    color: AppColors.brand,
                    height: 200,
                  ),
              ),
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  'النموذج يتعلم الاتجاه العام ونمط أيام الأسبوع (مثل انخفاض الجمعة) من آخر 120 يوماً، ويُعاد احتسابه مع كل فتح للصفحة. '
                  'النطاق المظلل هو المدى المتوقع بثقة 95%.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ arrears aging

class AgingTab extends StatelessWidget {
  const AgingTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/finance/aging',
      builder: (context, d, reload) {
        final buckets = (d['buckets'] as List).cast<Map>();
        final sectors = (d['sectors'] as List).cast<Map>();
        final top = (d['top'] as List).cast<Map>();
        // graded from fresh (good) to very old (bad)
        final colors = [
          AppColors.good,
          Color.lerp(AppColors.good, AppColors.warn, 0.6)!,
          AppColors.warn,
          Color.lerp(AppColors.warn, AppColors.bad, 0.5)!,
          AppColors.bad,
        ];
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              KpiCard(
                width: 320,
                label: 'متأخرات تقديرية (الحصة الحكومية)',
                value: formatIqd(asNum(d['total_estimated'])),
                icon: Icons.hourglass_bottom,
                color: AppColors.warn,
              ),
              const SectionTitle('أعمار المتأخرات (أيام منذ آخر دفعة)'),
              AppCard(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(children: [
                    SimpleBarChart(
                      labels: buckets.map((b) => '${b['key']}').toList(),
                      values: buckets.map((b) => (asNum(b['estimated']) ?? 0).toDouble()).toList(),
                      colors: colors,
                      height: 200,
                    ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (var i = 0; i < buckets.length; i++)
                        StatusChip('${buckets[i]['label']} (${buckets[i]['key']}): ${buckets[i]['properties']} عقار', colors[i]),
                    ]),
                  ]),
              ),
              const SectionTitle('حسب القاطع'),
              AppCard(
                padding: const EdgeInsets.all(Gap.md),
                child: HBarList(
                    color: AppColors.warn,
                    rows: sectors
                        .map((s) => (
                              label: '${s['name']}',
                              value: (asNum(s['estimated']) ?? 0).toDouble(),
                              trailing: '${compactIqd((asNum(s['estimated']) ?? 0).toDouble())} | ${s['overdue']}/${s['properties']} متأخر',
                            ))
                        .toList(),
                  ),
              ),
              const SectionTitle('أعلى العقارات متأخرات'),
              if (top.isEmpty) const EmptyState(icon: Icons.task_alt, title: 'لا توجد عقارات متأخرة'),
              ...top.map((p) => Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: (asNum(p['days']) ?? 0) > 90 ? AppColors.bad.withValues(alpha: 0.12) : AppColors.warn.withValues(alpha: 0.12),
                        child: Text('${p['days']}',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: (asNum(p['days']) ?? 0) > 90 ? AppColors.bad : AppColors.warn)),
                      ),
                      title: Text('${p['property_code']} - ${p['citizen']}'),
                      subtitle: Text('${p['sector']} | ${p['address']} | ${p['never_paid'] == true ? 'لم يدفع منذ التسجيل' : 'آخر دفعة ${formatDate(p['last_paid'])}'}'),
                      trailing: Text(formatIqd(asNum(p['estimated'])), style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  )),
              Padding(padding: const EdgeInsets.all(8), child: Text('${d['note']}', style: const TextStyle(color: AppColors.muted, fontSize: 12))),
            ],
          ),
        );
      },
    );
  }
}

