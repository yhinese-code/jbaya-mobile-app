import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../shared/photo_dialog.dart';
import '../shared/ui.dart';

/// Supervisor review of previous bills entered or disputed at the house:
/// the paper-bill photo beside the amount, then confirm / reject, or pick imported vs field amount.
class PrevBillsReviewTab extends StatefulWidget {
  const PrevBillsReviewTab({super.key});

  @override
  State<PrevBillsReviewTab> createState() => _PrevBillsReviewTabState();
}

class _PrevBillsReviewTabState extends State<PrevBillsReviewTab> {
  final _view = GlobalKey<ApiViewState>();

  static const _actionTitles = {
    'confirm': 'اعتماد الفاتورة',
    'reject': 'رفض الفاتورة',
    'use_field_amount': 'اعتماد مبلغ الفاتورة الورقية',
    'keep_import': 'إبقاء مبلغ ملف الدائرة',
  };

  Future<void> _decide(Map r, String action) async {
    final note = await askNote(context, _actionTitles[action] ?? action, required: action == 'reject');
    if (note == null || !mounted) return;
    final res = await runApi(
      context,
      () => ApiClient.instance.post('/supervisor/prev-bills/${r['id']}/decision', {'action': action, 'note': note.isEmpty ? null : note}),
      success: action == 'reject' ? 'تم رفض الفاتورة' : 'تم الاعتماد',
    );
    if (res != null) await _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/supervisor/prev-bills',
      builder: (context, data, reload) {
        final List<Map> list = data is List ? data.whereType<Map>().toList() : <Map>[];
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              const Text(
                'فواتير سابقة أدخلها الجباة من الميدان أو وجدوها مختلفة عن ملف دائرة الماء. قارن الصورة بالمبلغ قبل القرار.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 8),
              if (list.isEmpty)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('لا توجد فواتير بانتظار المراجعة'))),
              ...list.map(_card),
            ],
          ),
        );
      },
    );
  }

  Widget _card(Map r) {
    final mismatch = r['status'] == 'mismatch';
    final flags = r['flags'] is List ? (r['flags'] as List).map((e) => '$e').toList() : const <String>[];
    final odd = flags.contains('odd_amount');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('${r['property_code']} - ${r['citizen_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              StatusChip(mismatch ? 'لا تطابق' : 'بانتظار المراجعة', mismatch ? Colors.red : Colors.orange),
            ]),
            if (r['address'] != null) Text('${r['address']}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 4),
            Text(
              '${r['source'] == 'import' ? 'من ملف دائرة الماء' : 'إدخال ميداني'}'
              ' | المدة ${r['period_days']} يوم'
              '${r['bill_date'] != null ? ' | بتاريخ ${formatDate(r['bill_date'])}' : ''}'
              '${r['entered_by'] != null ? ' | أدخلها: ${r['entered_by']}' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
            if (odd) ...[
              const SizedBox(height: 6),
              const StatusChip('مبلغ غير معتاد', Colors.deepOrange),
            ],
            const SizedBox(height: 8),
            if (mismatch)
              Row(children: [
                Expanded(child: _amountBox('مبلغ ملف الدائرة', asNum(r['amount']), Colors.blueGrey)),
                const SizedBox(width: 8),
                Expanded(child: _amountBox('مبلغ الفاتورة الورقية', asNum(r['field_amount']), Colors.deepOrange)),
              ])
            else
              _amountBox('المبلغ', asNum(r['amount']), Colors.teal),
            if (r['note'] != null && '${r['note']}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('ملاحظة: ${r['note']}', style: const TextStyle(color: Colors.grey)),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              if (r['has_photo'] == true)
                TextButton.icon(
                  onPressed: () => showEvidencePhoto(context, '/prev-bills/${r['id']}/photo', title: 'صورة الفاتورة الورقية'),
                  icon: const Icon(Icons.image),
                  label: const Text('الصورة'),
                ),
              if (mismatch) ...[
                ElevatedButton(
                  onPressed: () => _decide(r, 'use_field_amount'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange, foregroundColor: Colors.white),
                  child: const Text('اعتماد مبلغ الورقة'),
                ),
                OutlinedButton(
                  onPressed: () => _decide(r, 'keep_import'),
                  child: const Text('إبقاء مبلغ الملف'),
                ),
              ] else ...[
                ElevatedButton(
                  onPressed: () => _decide(r, 'confirm'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  child: const Text('اعتماد'),
                ),
                OutlinedButton(
                  onPressed: () => _decide(r, 'reject'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('رفض'),
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }

  Widget _amountBox(String label, num? amount, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        Text(formatIqd(amount), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }
}
