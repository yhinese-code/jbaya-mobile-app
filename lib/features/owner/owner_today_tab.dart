import 'package:flutter/material.dart';

import '../../core/format.dart';
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
      'confirmed' => Colors.green.shade700,
      'denied' => Colors.red.shade700,
      'wrong_amount' => Colors.deepOrange,
      'no_answer' => Colors.blueGrey,
      _ => Colors.grey,
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
        final changeColor = change == null ? Colors.grey : (up ? Colors.green.shade700 : Colors.red.shade700);
        final changeText = change == null
            ? 'لا مقارنة (لا تحصيل قبل 4 أسابيع)'
            : '${up ? '▲' : '▼'} ${(change.abs() * 100).toStringAsFixed(0)}% عن نفس اليوم قبل 4 أسابيع';
        final totalCallbacks = callbacks.values.fold<num>(0, (a, v) => a + (asNum(v) ?? 0));

        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
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
                  color: Colors.indigo,
                ),
                KpiCard(
                  label: 'دخل الشركة اليوم',
                  value: formatIqd(asNum(now['company_income'])),
                  sub: 'قبل 4 أسابيع: ${compactIqd((asNum(then['company_income']) ?? 0).toDouble())}',
                  icon: Icons.account_balance_wallet,
                  color: Colors.teal,
                ),
                KpiCard(
                  label: 'نقد خارج المقر',
                  value: formatIqd(asNum(d['cash_outside_hq'])),
                  sub: cashAlert ? 'فوق الحد المسموح!' : 'لدى الجباة والمشرفين',
                  icon: cashAlert ? Icons.warning_amber_rounded : Icons.directions_walk,
                  color: cashAlert ? Colors.red : Colors.brown,
                ),
                KpiCard(
                  label: 'استخدام الرمز الرئيسي اليوم',
                  value: formatNumber(asNum(d['master_code_uses'])),
                  icon: Icons.key,
                  color: (asNum(d['master_code_uses']) ?? 0) > 0 ? Colors.deepOrange : Colors.grey,
                ),
                KpiCard(
                  label: 'فروقات نقدية مفتوحة',
                  value: formatNumber(asNum(d['open_differences'])),
                  icon: Icons.report,
                  color: (asNum(d['open_differences']) ?? 0) > 0 ? Colors.orange : Colors.green,
                ),
                KpiCard(
                  label: 'استغاثات مفتوحة',
                  value: formatNumber(asNum(d['open_sos'])),
                  icon: Icons.sos,
                  color: (asNum(d['open_sos']) ?? 0) > 0 ? Colors.red : Colors.green,
                ),
              ]),
              const SectionTitle('اليوم مقابل نفس اليوم قبل 4 أسابيع'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    _compareRow('المحصّل', formatIqd(asNum(now['total'])), formatIqd(asNum(then['total'])), bold: true),
                    _compareRow('الوصولات', formatNumber(asNum(now['receipts'])), formatNumber(asNum(then['receipts']))),
                    _compareRow('دخل الشركة', formatIqd(asNum(now['company_income'])), formatIqd(asNum(then['company_income']))),
                    const Divider(),
                    Row(children: [
                      Icon(change == null ? Icons.remove : (up ? Icons.arrow_upward : Icons.arrow_downward), color: changeColor),
                      const SizedBox(width: 6),
                      Expanded(child: Text(changeText, style: TextStyle(color: changeColor, fontWeight: FontWeight.bold))),
                    ]),
                    const Text('تُحسب الأرقام حتى الساعة نفسها من اليوم.', style: TextStyle(fontSize: 11, color: Colors.grey)),
                  ]),
                ),
              ),
              SectionTitle('لم يبدأوا اليوم (${idle.length})'),
              Card(
                child: idle.isEmpty
                    ? const ListTile(
                        leading: Icon(Icons.check_circle, color: Colors.green),
                        title: Text('كل الجباة والمشرفين أصدروا وصلاً اليوم أو في إجازة'),
                      )
                    : Column(children: [
                        for (final e in idle)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.person_off, color: Colors.orange),
                            title: Text('${e['full_name']}'),
                            subtitle: Text('${e['employee_code']} | ${roleLabels['${e['role']}'] ?? e['role']}'),
                          ),
                      ]),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Text('لم يُصدر وصلاً اليوم وليس في إجازة معتمدة.', style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
              const SectionTitle('واتساب هذا الشهر'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(
                  label: 'رسائل مُرسلة',
                  value: formatNumber(asNum(wa['messages'])),
                  icon: Icons.chat,
                  color: Colors.green,
                ),
                KpiCard(
                  label: 'رسائل فشلت',
                  value: formatNumber(asNum(wa['failed'])),
                  icon: Icons.error_outline,
                  color: (asNum(wa['failed']) ?? 0) > 0 ? Colors.red : Colors.grey,
                ),
                KpiCard(
                  label: 'الكلفة التقديرية',
                  value: '\$${formatNumber(asNum(wa['cost_usd']), decimals: 2)}',
                  icon: Icons.attach_money,
                  color: Colors.indigo,
                ),
              ]),
              SectionTitle('الاتصال العشوائي بالمواطنين (آخر 30 يوماً: ${formatNumber(totalCallbacks)})'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: callbacks.isEmpty
                      ? const Text('لا اتصالات بعد', style: TextStyle(color: Colors.grey))
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final k in [..._callbackLabels.keys, ...callbacks.keys.map((e) => '$e').where((e) => !_callbackLabels.containsKey(e))])
                              if (callbacks.containsKey(k))
                                StatusChip('${_callbackLabels[k] ?? k}: ${formatNumber(asNum(callbacks[k]))}', _callbackColor(k)),
                          ]),
                          if ((asNum(callbacks['denied']) ?? 0) + (asNum(callbacks['wrong_amount']) ?? 0) > 0)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text('مواطنون أنكروا الدفع أو ذكروا مبلغاً مختلفاً: راجع القيادة وكشف التلاعب.',
                                  style: TextStyle(color: Colors.red, fontSize: 12)),
                            ),
                        ]),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _compareRow(String label, String now, String then, {bool bold = false}) {
    final style = TextStyle(fontWeight: bold ? FontWeight.bold : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(flex: 3, child: Text(label, style: style)),
        Expanded(flex: 4, child: Text('اليوم: $now', style: style)),
        Expanded(flex: 4, child: Text('قبل 4 أسابيع: $then', style: const TextStyle(color: Colors.grey))),
      ]),
    );
  }
}
