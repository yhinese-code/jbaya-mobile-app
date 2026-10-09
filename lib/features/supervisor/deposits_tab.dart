import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../shared/ui.dart';

/// Supervisor -> headquarters: the cash collected from the collectors is taken to the finance department,
/// which counts it. No bank deposits by supervisors.
class HandToFinanceTab extends StatelessWidget {
  const HandToFinanceTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        ApiView(
          path: '/supervisor/cash',
          builder: (context, c, reload) {
            final cash = (asNum(c['cash_to_hand_over']) ?? 0).toDouble();
            final pending = (asNum(c['reconciliations_pending_resolution']) ?? 0).toInt();
            final own = (asNum(c['own_collection']) ?? 0).toDouble();
            final ownReceipts = (asNum(c['own_receipts']) ?? 0).toInt();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AppCard(
                accent: cash > 0 ? AppColors.warn : null,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('النقد بحوزتك لتسليمه للمالية', style: TextStyle(color: AppColors.muted)),
                  const SizedBox(height: Gap.xs),
                  Text(formatIqd(cash),
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, fontFeatures: [FontFeature.tabularFigures()])),
                  Text('من ${c['reconciliations_ready']} تسليم من الجباة'),
                  if (own > 0 || ownReceipts > 0)
                    Text('من جبايتك الخاصة: ${formatIqd(own)} ($ownReceipts وصل)',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.brand)),
                  const SizedBox(height: Gap.sm),
                  const Text('احمل النقد إلى قسم المالية في المقر. ستعدّه المالية أمامك، ويُسجَّل أي فرق باسمك.',
                      style: TextStyle(color: AppColors.muted, fontSize: 12)),
                ]),
              ),
              if (pending > 0)
                NoticeBanner(
                  tone: Tone.bad,
                  title: 'لديك $pending فروقات لم تعالجها بعد',
                  message: 'عالجها في «المطابقة النقدية» قبل الذهاب للمقر.',
                ),
            ]);
          },
        ),
        const SectionTitle('ما سلّمته للمالية'),
        ApiView(
          path: '/supervisor/handovers',
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.business_outlined,
                title: 'لم تسلّم شيئاً للمالية بعد',
                message: 'كل تسليم تعدّه المالية سيظهر هنا مع أي فرق',
              );
            }
            return Column(
              children: list.map((h) {
                final diff = (asNum(h['difference']) ?? 0).toDouble();
                return AppCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    leading: Icon(diff == 0 ? Icons.check_circle : Icons.warning, color: diff == 0 ? AppColors.good : AppColors.bad),
                    title: Text('عدّت المالية ${formatIqd(asNum(h['counted_cash']))}'),
                    subtitle: Text('${formatDate(h['created_at'])} ${formatTime(h['created_at'])} | استلم: ${h['received_by']}'
                        '${diff != 0 ? '\n${diff < 0 ? 'نقص' : 'زيادة'} ${formatIqd(diff.abs())}${h['resolution_note'] != null ? ' — ${h['resolution_note']}' : ''}' : ''}'),
                    isThreeLine: diff != 0,
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}
