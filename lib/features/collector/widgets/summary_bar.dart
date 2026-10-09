import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/format.dart';
import '../../../core/theme.dart';

/// Today's figures for the collector: what he collected, cash in hand vs the cap (no targets).
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
    final cash = (asNum(s['cash_in_hand']) ?? 0).toDouble();
    final cap = (asNum(s['cash_cap']) ?? 1).toDouble();
    final cashRatio = cap <= 0 ? 0.0 : (cash / cap).clamp(0.0, 1.0);
    final cashColor = cashRatio >= 1 ? AppColors.bad : (cashRatio >= 0.8 ? AppColors.warn : AppColors.brand);
    final masterUses = (asNum(s['master_code_uses_today']) ?? 0) > 0;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // No daily target here: the collector never sees performance targets as numbers.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('المحصّل اليوم', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                    Text(formatIqd(collected),
                        style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.good, fontSize: 17)),
                  ],
                ),
              ),
              const SizedBox(width: Gap.lg),
              Expanded(child: _meter('النقد بحوزتك', formatIqd(cash), 'من ${formatIqd(cap)}', cashRatio, cashColor)),
            ],
          ),
          const SizedBox(height: Gap.sm),
          Wrap(
            spacing: Gap.lg,
            runSpacing: Gap.xs,
            children: [
              _fact(Icons.receipt_long_outlined, 'وصولات اليوم', '${s['receipts_today']}'),
              _fact(Icons.person_add_alt_1_outlined, 'تسجيلات اليوم', '${s['registrations_today']}'),
              if (masterUses) _fact(Icons.key_outlined, 'الرمز الرئيسي', '${s['master_code_uses_today']}', color: AppColors.warn),
            ],
          ),
          if (s['cash_cap_reached'] == true)
            const NoticeBanner(
              tone: Tone.bad,
              icon: Icons.account_balance_wallet_outlined,
              title: 'وصلت الحد الأعلى للنقد',
              message: 'سلّم المبالغ للمشرف لتتمكن من متابعة الجباية.',
            )
          else if (cashRatio >= 0.8)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text('اقتربت من الحد الأعلى للنقد، رتّب التسليم مع المشرف',
                  style: const TextStyle(color: AppColors.warn, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          if (s['open_sos'] != null)
            NoticeBanner(
              tone: Tone.bad,
              icon: Icons.sos,
              title: s['open_sos']['status'] == 'acknowledged'
                  ? 'تم استلام نداء الاستغاثة. الدعم في الطريق'
                  : 'تم إرسال نداء الاستغاثة. بانتظار الاستجابة',
            ),
        ],
      ),
    );
  }

  Widget _fact(IconData icon, String label, String value, {Color color = AppColors.muted}) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: Gap.xs),
      Text('$label: ', style: TextStyle(fontSize: 12, color: color)),
      Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.ink)),
    ]);
  }

  Widget _meter(String label, String value, String of, double ratio, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: color, fontSize: 17)),
        const SizedBox(height: Gap.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: ratio, color: color, backgroundColor: color.withValues(alpha: 0.15), minHeight: 6),
        ),
        const SizedBox(height: 2),
        Text(of, style: const TextStyle(fontSize: 11, color: AppColors.muted)),
      ],
    );
  }
}
