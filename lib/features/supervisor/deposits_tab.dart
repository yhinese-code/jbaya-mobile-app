import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../shared/ui.dart';

/// Supervisor -> headquarters: the cash collected from the collectors is taken to the finance department,
/// which counts it. No bank deposits by supervisors.
class HandToFinanceTab extends StatelessWidget {
  const HandToFinanceTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ApiView(
          path: '/supervisor/cash',
          builder: (context, c, reload) {
            final cash = (asNum(c['cash_to_hand_over']) ?? 0).toDouble();
            final pending = (asNum(c['reconciliations_pending_resolution']) ?? 0).toInt();
            return Card(
              color: cash > 0 ? Colors.orange.withValues(alpha: 0.08) : null,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('النقد بحوزتك لتسليمه للمالية', style: TextStyle(color: Colors.grey)),
                  Text(formatIqd(cash), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                  Text('من ${c['reconciliations_ready']} تسليم من الجباة'),
                  if (pending > 0)
                    Text('لديك $pending فروقات لم تعالجها بعد؛ عالجها في «المطابقة النقدية» قبل الذهاب للمقر.',
                        style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 8),
                  const Text('احمل النقد إلى قسم المالية في المقر. ستعدّه المالية أمامك، ويُسجَّل أي فرق باسمك.',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ]),
              ),
            );
          },
        ),
        const SectionTitle('ما سلّمته للمالية'),
        ApiView(
          path: '/supervisor/handovers',
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            if (list.isEmpty) return const Text('لم تسلّم شيئاً بعد', style: TextStyle(color: Colors.grey));
            return Column(
              children: list.map((h) {
                final diff = (asNum(h['difference']) ?? 0).toDouble();
                return Card(
                  child: ListTile(
                    leading: Icon(diff == 0 ? Icons.check_circle : Icons.warning, color: diff == 0 ? Colors.green : Colors.red),
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
