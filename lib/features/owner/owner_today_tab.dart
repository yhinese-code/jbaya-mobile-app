import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../finance/charts.dart';
import '../shared/ui.dart';

const Map<String, String> _callbackLabels = {
  'pending': 'لم يُتصل بعد',
  'confirmed': 'أكّد الدفع',
  'denied': 'أنكر الدفع',
  'wrong_amount': 'مبلغ مختلف',
  'no_answer': 'لم يرد',
};

Color _callbackColor(String s) => switch (s) {
      'confirmed' => AppColors.good,
      'denied' => AppColors.bad,
      'wrong_amount' => AppColors.warn,
      'no_answer' => AppColors.muted,
      _ => AppColors.muted,
    };

/// 'يومي': the owner's day at a glance (GET /owner/today).
class OwnerTodayTab extends StatelessWidget {
  const OwnerTodayTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/owner/today',
      builder: (context, data, reload) {
        final d = data as Map;
        final now = d['collected'] is Map ? d['collected'] as Map : const {};
        final then = d['same_weekday_4_weeks_ago'] is Map ? d['same_weekday_4_weeks_ago'] as Map : const {};
        final change = asNum(d['change'])?.toDouble();
        final idle = ((d['not_started'] as List?) ?? const []).whereType<Map>().toList();
        final wa = d['whatsapp_month'] is Map ? d['whatsapp_month'] as Map : const {};
        final callbacks = d['callbacks_30_days'] is Map ? d['callbacks_30_days'] as Map : const {};
        final cashAlert = d['cash_alert'] == true;
        final up = change != null && change >= 0;
        final changeColor = change == null ? AppColors.muted : (up ? AppColors.good : AppColors.bad);
        final changeText = change == null
            ? 'لا مقارنة (لا تحصيل قبل 4 أسابيع)'
            : '${up ? '▲' : '▼'} ${(change.abs() * 100).toStringAsFixed(0)}% عن نفس اليوم قبل 4 أسابيع';
        final totalCallbacks = callbacks.values.fold<num>(0, (a, v) => a + (asNum(v) ?? 0));

        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              Text('اليوم ${formatDate(d['today'])}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(
                  label: 'المحصّل اليوم',
                  value: formatIqd(asNum(now['total'])),
                  sub: changeText,
                  icon: up ? Icons.trending_up : Icons.trending_down,
                  color: changeColor,
                  width: 280,
                ),
                KpiCard(
                  label: 'وصولات اليوم',
                  value: formatNumber(asNum(now['receipts'])),
                  sub: 'قبل 4 أسابيع: ${formatNumber(asNum(then['receipts']))}',
                  icon: Icons.receipt_long,
                  color: AppColors.brand,
                ),
                KpiCard(
                  label: 'دخل الشركة اليوم',
                  value: formatIqd(asNum(now['company_income'])),
                  sub: 'قبل 4 أسابيع: ${compactIqd((asNum(then['company_income']) ?? 0).toDouble())}',
                  icon: Icons.account_balance_wallet,
                  color: AppColors.brand,
                ),
                KpiCard(
                  label: 'نقد خارج المقر',
                  value: formatIqd(asNum(d['cash_outside_hq'])),
                  sub: cashAlert ? 'فوق الحد المسموح!' : 'لدى الجباة والمشرفين',
                  icon: cashAlert ? Icons.warning_amber_rounded : Icons.directions_walk,
                  color: cashAlert ? AppColors.bad : AppColors.muted,
                ),
                KpiCard(
                  label: 'استخدام الرمز الرئيسي اليوم',
                  value: formatNumber(asNum(d['master_code_uses'])),
                  icon: Icons.key,
                  color: (asNum(d['master_code_uses']) ?? 0) > 0 ? AppColors.warn : AppColors.muted,
                ),
                KpiCard(
                  label: 'فروقات نقدية مفتوحة',
                  value: formatNumber(asNum(d['open_differences'])),
                  icon: Icons.report,
                  color: (asNum(d['open_differences']) ?? 0) > 0 ? AppColors.warn : AppColors.good,
                ),
                KpiCard(
                  label: 'استغاثات مفتوحة',
                  value: formatNumber(asNum(d['open_sos'])),
                  icon: Icons.sos,
                  color: (asNum(d['open_sos']) ?? 0) > 0 ? AppColors.bad : AppColors.good,
                ),
              ]),
              const SectionTitle('اليوم مقابل نفس اليوم قبل 4 أسابيع'),
              AppCard(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(children: [
                    _compareHeader(),
                    _compareRow('المحصّل', formatIqd(asNum(now['total'])), formatIqd(asNum(then['total'])), bold: true),
                    _compareRow('الوصولات', formatNumber(asNum(now['receipts'])), formatNumber(asNum(then['receipts']))),
                    _compareRow('دخل الشركة', formatIqd(asNum(now['company_income'])), formatIqd(asNum(then['company_income']))),
                    const Divider(),
                    Row(children: [
                      Icon(change == null ? Icons.remove : (up ? Icons.arrow_upward : Icons.arrow_downward), color: changeColor),
                      const SizedBox(width: 6),
                      Expanded(child: Text(changeText, style: TextStyle(color: changeColor, fontWeight: FontWeight.bold))),
                    ]),
                    const Text('تُحسب الأرقام حتى الساعة نفسها من اليوم.', style: TextStyle(fontSize: 11, color: AppColors.muted)),
                  ]),
              ),
              SectionTitle('لم يبدأوا اليوم (${idle.length})'),
              AppCard(
                padding: EdgeInsets.zero,
                child: idle.isEmpty
                    ? const ListTile(
                        leading: Icon(Icons.check_circle, color: AppColors.good),
                        title: Text('كل الجباة والمشرفين أصدروا وصلاً اليوم أو في إجازة'),
                      )
                    : Column(children: [
                        for (final e in idle)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.person_off, color: AppColors.warn),
                            title: Text('${e['full_name']}'),
                            subtitle: Text('${e['employee_code']} | ${roleLabels['${e['role']}'] ?? e['role']}'),
                          ),
                      ]),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('لم يُصدر وصلاً اليوم وليس في إجازة معتمدة.', style: TextStyle(fontSize: 11, color: AppColors.muted)),
              ),
              const SectionTitle('واتساب هذا الشهر'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(
                  label: 'رسائل مُرسلة',
                  value: formatNumber(asNum(wa['messages'])),
                  icon: Icons.chat,
                  color: AppColors.good,
                ),
                KpiCard(
                  label: 'رسائل فشلت',
                  value: formatNumber(asNum(wa['failed'])),
                  icon: Icons.error_outline,
                  color: (asNum(wa['failed']) ?? 0) > 0 ? AppColors.bad : AppColors.muted,
                ),
                KpiCard(
                  label: 'رسائل مجانية',
                  value: formatNumber(asNum(wa['free_messages'])),
                  sub: 'بلا كلفة',
                  icon: Icons.money_off,
                  color: AppColors.good,
                ),
                KpiCard(
                  label: 'الكلفة التقديرية',
                  value: '\$${formatNumber(asNum(wa['cost_usd']), decimals: 2)}',
                  sub: 'الرسائل المجانية لا تُحتسب',
                  icon: Icons.attach_money,
                  color: AppColors.brand,
                ),
              ]),
              SectionTitle('الاتصال العشوائي بالمواطنين (آخر 30 يوماً: ${formatNumber(totalCallbacks)})'),
              AppCard(
                padding: const EdgeInsets.all(Gap.md),
                child: callbacks.isEmpty
                      ? const Text('لا اتصالات بعد. تظهر هنا نتائج الاتصال العشوائي بالمواطنين للتحقق من الدفع.',
                          style: TextStyle(color: AppColors.muted))
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final k in [..._callbackLabels.keys, ...callbacks.keys.map((e) => '$e').where((e) => !_callbackLabels.containsKey(e))])
                              if (callbacks.containsKey(k))
                                StatusChip('${_callbackLabels[k] ?? k}: ${formatNumber(asNum(callbacks[k]))}', _callbackColor(k)),
                          ]),
                          if ((asNum(callbacks['denied']) ?? 0) + (asNum(callbacks['wrong_amount']) ?? 0) > 0) ...[
                            const SizedBox(height: Gap.sm),
                            const NoticeBanner(
                              tone: Tone.bad,
                              title: 'مواطنون أنكروا الدفع أو ذكروا مبلغاً مختلفاً',
                              message: 'راجع القيادة وكشف التلاعب.',
                            ),
                          ],
                        ]),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _compareHeader() {
    const style = TextStyle(fontSize: 12, color: AppColors.muted, fontWeight: FontWeight.w600);
    return const Padding(
      padding: EdgeInsets.only(bottom: Gap.xs),
      child: Row(children: [
        Expanded(flex: 3, child: SizedBox()),
        Expanded(flex: 4, child: Text('اليوم', textAlign: TextAlign.end, style: style)),
        Expanded(flex: 4, child: Text('قبل 4 أسابيع', textAlign: TextAlign.end, style: style)),
      ]),
    );
  }

  Widget _compareRow(String label, String now, String then, {bool bold = false}) {
    const nums = [FontFeature.tabularFigures()];
    final style = TextStyle(fontWeight: bold ? FontWeight.bold : null, fontFeatures: nums);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(flex: 3, child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.bold : null))),
        Expanded(flex: 4, child: Text(now, textAlign: TextAlign.end, style: style)),
        Expanded(
            flex: 4,
            child: Text(then, textAlign: TextAlign.end, style: const TextStyle(color: AppColors.muted, fontFeatures: nums))),
      ]),
    );
  }
}
