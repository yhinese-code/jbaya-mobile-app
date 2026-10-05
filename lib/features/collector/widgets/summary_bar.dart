import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/format.dart';

/// Today's progress for the collector: collected vs target, cash in hand vs the cap.
class SummaryBar extends StatefulWidget {
  const SummaryBar({super.key});

  @override
  State<SummaryBar> createState() => SummaryBarState();
}

class SummaryBarState extends State<SummaryBar> {
  Map<String, dynamic>? _s;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final res = await ApiClient.instance.get('/collector/summary');
      if (mounted) setState(() => _s = Map<String, dynamic>.from(res as Map));
    } on ApiException catch (_) {
      // the bar is informational; screens show their own errors
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) return const LinearProgressIndicator(minHeight: 2);
    final collected = (asNum(s['collected_today']) ?? 0).toDouble();
    final target = (asNum(s['daily_target']) ?? 0).toDouble();
    final cash = (asNum(s['cash_in_hand']) ?? 0).toDouble();
    final cap = (asNum(s['cash_cap']) ?? 1).toDouble();
    final cashRatio = cap <= 0 ? 0.0 : (cash / cap).clamp(0.0, 1.0);
    final cashColor = cashRatio >= 1 ? Colors.red : (cashRatio >= 0.8 ? Colors.orange : Colors.teal);

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _meter(
                  'المحصّل اليوم',
                  '${formatIqd(collected)} / ${formatIqd(target)}',
                  target <= 0 ? 0 : (collected / target).clamp(0.0, 1.0),
                  Colors.green,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(child: _meter('النقد بحوزتك', '${formatIqd(cash)} / ${formatIqd(cap)}', cashRatio, cashColor)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Text('وصولات اليوم: ${s['receipts_today']}', style: const TextStyle(fontSize: 12)),
              Text('تسجيلات اليوم: ${s['registrations_today']}', style: const TextStyle(fontSize: 12)),
              if ((asNum(s['master_code_uses_today']) ?? 0) > 0)
                Text('الرمز الرئيسي: ${s['master_code_uses_today']}', style: const TextStyle(fontSize: 12, color: Colors.orange)),
            ],
          ),
          if (s['cash_cap_reached'] == true)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              width: double.infinity,
              color: Colors.red.shade50,
              child: const Text(
                'وصلت الحد الأعلى للنقد. سلّم المبالغ للمشرف لتتمكن من متابعة الجباية.',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            )
          else if (cashRatio >= 0.8)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('اقتربت من الحد الأعلى للنقد، رتّب التسليم مع المشرف',
                  style: TextStyle(color: Colors.orange.shade800, fontSize: 12)),
            ),
          if (s['open_sos'] != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              width: double.infinity,
              color: Colors.red.shade100,
              child: Text(
                s['open_sos']['status'] == 'acknowledged'
                    ? 'تم استلام نداء الاستغاثة. الدعم في الطريق'
                    : 'تم إرسال نداء الاستغاثة. بانتظار الاستجابة',
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
    );
  }

  Widget _meter(String label, String value, double ratio, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 13)),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: ratio, color: color, backgroundColor: color.withValues(alpha: 0.15), minHeight: 6),
      ],
    );
  }
}
