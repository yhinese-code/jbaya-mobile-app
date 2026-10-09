import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../finance/charts.dart';
import '../hr/hr_tabs.dart' show currentPeriod, recentPeriods;
import '../shared/ui.dart';

const _statusColors = {
  'profitable': AppColors.good,
  'losing': AppColors.bad,
  'leave': AppColors.info,
  'today': AppColors.faint,
  'extra': AppColors.brand,
};
const _statusLabels = {
  'profitable': 'غطّى كلفته',
  'losing': 'لم يغطِّ كلفته',
  'leave': 'إجازة',
  'today': 'اليوم (جارٍ)',
  'extra': 'عطلة بعمل إضافي',
};

/// Labels for the collector's own strip: no cost / money wording.
const _coachStatusLabels = {
  'profitable': 'يوم جيد',
  'losing': 'يوم ضعيف',
  'leave': 'إجازة',
  'today': 'اليوم (جارٍ)',
  'extra': 'عطلة بعمل إضافي',
};

/// A row of small day squares (green = covered his cost, red = didn't, blue = leave).
/// With [showCounts] false (the collector's own card) the squares carry colours only: no counts anywhere.
class DayStrip extends StatelessWidget {
  final List<Map> days;
  final bool showCounts;
  const DayStrip({super.key, required this.days, this.showCounts = true});

  @override
  Widget build(BuildContext context) {
    if (!showCounts) {
      return Wrap(
        spacing: 3,
        runSpacing: 3,
        children: days.map((d) {
          final c = _statusColors[d['status']] ?? AppColors.muted;
          return Tooltip(
            message: _coachStatusLabels[d['status']] ?? '',
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(color: c.withValues(alpha: d['status'] == 'today' ? 0.35 : 0.85), borderRadius: BorderRadius.circular(3)),
            ),
          );
        }).toList(),
      );
    }
    return Wrap(
      spacing: 3,
      runSpacing: 3,
      children: days.map((d) {
        final c = _statusColors[d['status']] ?? AppColors.muted;
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
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, 0),
        child: Row(children: [
          DropdownButton<String>(
            value: _period,
            items: {...recentPeriods(), _period}.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
            onChanged: (v) => setState(() => _period = v ?? _period),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('كلفة الجابي اليومية = (الراتب + المخصصات) ÷ أيام العمل + عمولته. ما تكسبه الشركة منه = أجور الخدمة + حصتها من مبالغ الماء.',
                style: TextStyle(color: AppColors.muted, fontSize: 12)),
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
                padding: const EdgeInsets.all(Gap.md),
                children: [
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    KpiCard(label: 'ما كسبته الشركة من الجباة', value: formatIqd(asNum(t['earnings'])), icon: Icons.trending_up, color: AppColors.good),
                    KpiCard(label: 'كلفة الجباة (رواتب وعمولات)', value: formatIqd(asNum(t['cost'])), icon: Icons.payments, color: AppColors.warn),
                    KpiCard(
                      label: 'الفرق',
                      value: formatIqd(asNum(t['net'])),
                      icon: Icons.balance,
                      color: (asNum(t['net']) ?? 0) >= 0 ? AppColors.brand : AppColors.bad,
                    ),
                    KpiCard(
                      label: 'جباة متقاعسون',
                      value: '${t['flagged']}',
                      sub: '${d['streak_alert_days']} أيام متتالية أو أكثر دون تغطية الكلفة',
                      icon: Icons.flag,
                      color: (asNum(t['flagged']) ?? 0) > 0 ? AppColors.bad : AppColors.good,
                    ),
                    KpiCard(label: 'معدل الفريق اليومي', value: '${d['team_avg_receipts_per_day']} وصل', icon: Icons.groups, color: AppColors.muted),
                  ]),
                  if (company != null) ...[
                    const SectionTitle('نقطة التعادل للشركة (هذا الشهر)'),
                    AppCard(
                      padding: const EdgeInsets.all(Gap.md),
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
                            color: company['on_track'] == true ? AppColors.good : AppColors.warn,
                          ),
                          const SizedBox(height: 4),
                          Text('حتى الآن ${company['receipts_this_month']} وصلاً بعد ${company['working_days_done']} من ${company['working_days']} يوم عمل '
                              '— ${company['on_track'] == true ? 'ضمن المسار' : 'متأخرون عن المسار'}',
                              style: TextStyle(color: company['on_track'] == true ? AppColors.good : AppColors.warn)),
                        ]),
                    ),
                  ],
                  const SectionTitle('الجباة: من يغطي كلفته؟'),
                  _legend(),
                  const SizedBox(height: 8),
                  if (rows.isEmpty) const EmptyState(icon: Icons.groups_outlined, title: 'لا توجد بيانات جباة لهذا الشهر'),
                  ...rows.map((c) {
                    final net = (asNum(c['net']) ?? 0).toDouble();
                    final flag = c['lazy_flag'] == true;
                    return AppCard(
                      accent: flag ? AppColors.bad : null,
                      padding: const EdgeInsets.all(Gap.md),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            if (flag) const Padding(padding: EdgeInsetsDirectional.only(end: 6), child: Icon(Icons.flag, color: AppColors.bad)),
                            Expanded(child: Text('${c['employee_code']} - ${c['full_name']}', style: const TextStyle(fontWeight: FontWeight.bold))),
                            StatusChip('${c['label']}', flag ? AppColors.bad : (net >= 0 ? AppColors.good : AppColors.warn)),
                          ]),
                          const SizedBox(height: 6),
                          Wrap(spacing: 14, runSpacing: 4, children: [
                            Text('كسبت الشركة منه: ${formatIqd(asNum(c['earnings']))}'),
                            Text('كلفته: ${formatIqd(asNum(c['cost']))}'),
                            Text('الفرق: ${formatIqd(net)}', style: TextStyle(fontWeight: FontWeight.bold, color: net >= 0 ? AppColors.good : AppColors.bad)),
                            Text('كلفته اليومية: ${formatIqd(asNum(c['daily_fixed_cost']))}'),
                            Text('هدف التعادل: ${c['breakeven_receipts_per_day'] ?? '-'} وصل/يوم'),
                            Text('معدله: ${c['receipts_per_day'] ?? '-'} وصل/يوم'),
                            Text('أيام غطّى فيها كلفته ${c['profitable_days']} | لم يغطِّ ${c['losing_days']}'),
                            if ((asNum(c['losing_streak']) ?? 0) > 0)
                              Text('متتالية: ${c['losing_streak']}', style: const TextStyle(color: AppColors.bad)),
                          ]),
                          const SizedBox(height: 8),
                          DayStrip(days: (c['days'] as List).cast<Map>()),
                        ]),
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
        final banner = d['banner'] is Map ? d['banner'] as Map : null;
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              if (banner != null)
                _TeamBanner(banner)
              else if (laggards > 0)
                NoticeBanner(
                  tone: Tone.bad,
                  icon: Icons.flag,
                  title: laggards == 1 ? 'لديك موظف متأخر يحتاج متابعة' : 'لديك $laggards موظفين متأخرين يحتاجون متابعة',
                  message: 'لم يحققوا هدفهم اليومي لعدة أيام متتالية',
                ),
              Text('معدل الفريق: ${d['team_avg_receipts_per_day']} منزل في اليوم', style: const TextStyle(color: AppColors.muted)),
              const SizedBox(height: 6),
              _legend(),
              const SizedBox(height: 8),
              if (rows.isEmpty) const EmptyState(icon: Icons.groups_outlined, title: 'لا يوجد جباة في فريقك'),
              ...rows.map((c) {
                final target = (asNum(c['daily_target']) ?? 0).toInt();
                final today = (asNum(c['today_receipts']) ?? 0).toInt();
                final flag = c['flag'] == true;
                return AppCard(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text('${c['employee_code']} - ${c['full_name']}', style: const TextStyle(fontWeight: FontWeight.bold))),
                        StatusChip('${c['label']}', flag ? AppColors.bad : (c['label'] == 'ضمن الهدف' ? AppColors.good : AppColors.warn)),
                      ]),
                      const SizedBox(height: 6),
                      Text('اليوم: $today من ${housesAr(target)}${(asNum(c['remaining_today']) ?? 0) > 0 ? ' — يحتاج ${housesAr((asNum(c['remaining_today']) ?? 0).toInt())} أخرى' : ' — حقق الهدف'}'),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: target > 0 ? (today / target).clamp(0.0, 1.0).toDouble() : 0,
                        minHeight: 8,
                        color: today >= target ? AppColors.good : AppColors.warn,
                      ),
                      const SizedBox(height: 6),
                      Text('معدله هذا الشهر ${c['receipts_per_day'] ?? '-'} منزل/يوم | أيام جيدة ${c['good_days']} | أيام ضعيفة ${c['weak_days']}',
                          style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                      const SizedBox(height: 6),
                      DayStrip(days: (c['days'] as List).cast<Map>()),
                    ]),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}

/// The team's verdict at the top of the supervisor's performance tab (red when the team is under the required level).
class _TeamBanner extends StatelessWidget {
  final Map banner;
  const _TeamBanner(this.banner);

  @override
  Widget build(BuildContext context) {
    final level = '${banner['level']}';
    final Tone tone;
    final IconData icon;
    switch (level) {
      case 'bad':
        tone = Tone.bad;
        icon = Icons.report;
        break;
      case 'warn':
        tone = Tone.warn;
        icon = Icons.warning_amber_rounded;
        break;
      default:
        tone = Tone.good;
        icon = Icons.verified;
    }
    final title = '${banner['title'] ?? (level == 'bad' ? 'فريقك دون المستوى المطلوب' : '')}';
    final text = banner['text'] == null ? '' : '${banner['text']}';
    return NoticeBanner(tone: tone, icon: icon, title: title, message: text.isEmpty ? null : text);
  }
}

// ================================================================ collector: his own coaching card

/// The collector's (and field supervisor's) own card: on track / behind / underperforming.
/// Deliberately shows NO numbers: only a colour, a title, the server's messages and a colour-only day strip.
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
      if (mounted && c is Map) setState(() => _c = c);
    } on ApiException catch (_) {
      // informational only
    }
  }

  static const _levelColors = {
    'good': AppColors.good,
    'info': AppColors.info,
    'warn': AppColors.warn,
    'bad': AppColors.bad,
  };

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || c['status'] == null) return const SizedBox.shrink();
    final status = '${c['status']}';
    final Color color;
    final IconData icon;
    switch (status) {
      case 'underperforming':
        color = AppColors.bad;
        icon = Icons.error;
        break;
      case 'behind':
        color = AppColors.warn;
        icon = Icons.trending_down;
        break;
      default:
        color = AppColors.good;
        icon = Icons.check_circle;
    }
    final msgs = (c['messages'] is List ? c['messages'] as List : const []).whereType<Map>().toList();
    final days = (c['days'] is List ? c['days'] as List : const []).whereType<Map>().toList();
    return Material(
      color: color.withValues(alpha: 0.10),
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Container(
          decoration: BoxDecoration(border: BorderDirectional(start: BorderSide(color: color, width: 5))),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${c['title'] ?? ''}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
              ),
              Icon(_open ? Icons.expand_less : Icons.expand_more, color: AppColors.muted),
            ]),
            if (_open) ...[
              ...msgs.map((m) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('• ${m['text'] ?? ''}', style: TextStyle(color: _levelColors[m['level']] ?? AppColors.ink, fontSize: 13)),
                  )),
              if (days.isNotEmpty) ...[
                const SizedBox(height: 8),
                DayStrip(days: days, showCounts: false),
              ],
            ],
          ]),
        ),
      ),
    );
  }
}
