import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../shared/ui.dart';
import 'charts.dart';

const _monthNames = [
  'كانون الثاني',
  'شباط',
  'آذار',
  'نيسان',
  'أيار',
  'حزيران',
  'تموز',
  'آب',
  'أيلول',
  'تشرين الأول',
  'تشرين الثاني',
  'كانون الأول',
];

String _monthLabel(String ym) {
  final m = int.tryParse(ym.length >= 7 ? ym.substring(5, 7) : '') ?? 0;
  if (m < 1 || m > 12) return ym;
  return '${_monthNames[m - 1]} ${ym.substring(0, 4)}';
}

String _currentMonth() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}';
}

const Map<String, String> _settlementLabels = {
  'pending_owner': 'بانتظار المالك',
  'posted': 'مقيّدة',
  'rejected': 'مرفوضة',
};

Color _settlementColor(String s) => switch (s) {
      'posted' => Colors.green.shade700,
      'rejected' => Colors.red.shade700,
      _ => Colors.orange.shade800,
    };

/// 'صيغة الـ35%': the company's share of the increase in collections, both candidate formulas side by side.
/// Shared by the finance portal and the owner portal (GET /finance/gain-share).
class GainShareTab extends StatefulWidget {
  const GainShareTab({super.key});

  @override
  State<GainShareTab> createState() => _GainShareTabState();
}

class _GainShareTabState extends State<GainShareTab> {
  final _view = GlobalKey<ApiViewState>();

  bool get _isFinance => Session.instance.role == 'finance';
  bool get _canEditBaselines => const ['finance', 'owner', 'admin', 'tech'].contains(Session.instance.role);

  Future<void> _settle(String month, num? amount) async {
    final ok = await confirm(
      context,
      'طلب التسوية',
      'سيُرسل طلب تقييد حصة الشركة من الزيادة لشهر ${_monthLabel(month)} (${formatIqd(amount)}) إلى المالك للموافقة.',
    );
    if (!ok || !mounted) return;
    final r = await runApi(context, () => ApiClient.instance.post('/finance/gain-share/settle', {'month': month}),
        success: 'أُرسل الطلب إلى المالك');
    if (r != null) _view.currentState?.reload();
  }

  Future<void> _editBaseline(String month, Map? current) async {
    final amountC = TextEditingController(text: current == null ? '' : formatNumber(asNum(current['amount'])).replaceAll(',', ''));
    final noteC = TextEditingController(text: current?['note']?.toString() ?? '');
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('إيرادات ${_monthLabel(month)}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('ما جُبي من الماء في هذا الشهر من سنة 2025 (قبل الشركة). الزيادة تُحسب فوق هذا المبلغ.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: amountC,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'المبلغ (د.ع)',
                border: const OutlineInputBorder(),
                errorText: error,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: noteC,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'ملاحظة / المصدر (اختياري)', border: OutlineInputBorder()),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () {
                final v = num.tryParse(amountC.text.replaceAll(',', '').trim());
                if (v == null || v < 0) {
                  setD(() => error = 'أدخل مبلغاً صحيحاً');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    final amount = num.tryParse(amountC.text.replaceAll(',', '').trim());
    final note = noteC.text.trim();
    Future.delayed(const Duration(milliseconds: 400), () {
      amountC.dispose();
      noteC.dispose();
    });
    if (ok != true || amount == null || !mounted) return;
    final r = await runApi(
      context,
      () => ApiClient.instance.post('/finance/gain-share/baselines', {
        'month': month,
        'amount': amount,
        'note': note.isEmpty ? null : note,
      }),
      success: 'تم الحفظ',
    );
    if (r != null) _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/finance/gain-share?months=6',
      builder: (context, data, reload) {
        final d = data as Map;
        final mode = '${d['mode'] ?? 'not_set'}';
        final pct = asNum(d['pct']) ?? 35;
        final pctStr = formatNumber(pct, decimals: pct % 1 == 0 ? 0 : 1);
        final confirmed = d['confirmed'] == true;
        final months = ((d['months'] as List?) ?? const []).whereType<Map>().toList();
        final baselines = {
          for (final b in ((d['baselines'] as List?) ?? const []).whereType<Map>()) '${b['month']}': b,
        };
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _header(d, mode, pctStr),
              if (!confirmed) _notConfirmedCard(),
              const SectionTitle('آخر 6 أشهر: الخياران جنباً إلى جنب'),
              if (months.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('لا بيانات بعد'))),
              ...months.map((m) => _monthCard(m, mode, pctStr)),
              SectionTitle('إيرادات 2025 (الأساس)',
                  actions: [Text('${baselines.length}/12 شهراً', style: const TextStyle(color: Colors.grey))]),
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text('ما جُبي في كل شهر من 2025. يُستخدم في الخيار (أ): الزيادة = المحصّل هذا الشهر − نفس الشهر من 2025.',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ),
              Card(
                child: Column(children: [
                  for (var i = 1; i <= 12; i++) _baselineRow('2025-${i.toString().padLeft(2, '0')}', baselines),
                ]),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _header(Map d, String mode, String pctStr) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.percent, color: Colors.indigo),
            const SizedBox(width: 8),
            const Expanded(child: Text('صيغة الـ35%', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            StatusChip('${d['mode_label'] ?? mode}', mode == 'not_set' ? Colors.orange.shade800 : Colors.indigo),
          ]),
          const SizedBox(height: 8),
          Text('الشركة تأخذ أجور الجباية على كل وصل (${formatIqd(asNum(d['fee']))}) + نسبة $pctStr% من الزيادة.',
              style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 6),
          const Text('(أ) فوق إيرادات 2025: الزيادة هي ما جُبي هذا الشهر فوق ما جُبي في نفس الشهر من 2025، تُسوّى شهرياً بموافقة المالك.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const Text('(ب) زيادة كل منزل: الزيادة هي ما يدفعه كل منزل فوق فاتورته السابقة لنفس عدد الأيام، تُقيّد على كل وصل.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          if (d['note'] != null) ...[
            const SizedBox(height: 6),
            Text('${d['note']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ]),
      ),
    );
  }

  Widget _notConfirmedCard() {
    final amber = Colors.amber.shade800;
    return Card(
      color: Colors.amber.withValues(alpha: 0.15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: amber, width: 1.5)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_amber_rounded, color: amber, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('أدخل صيغة الـ35% هنا', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: amber)),
              const SizedBox(height: 4),
              const Text('الصيغة لم تُحدد بعد. تُحدد من الإدارة التقنية بعد تأكيد العقد. الأرقام أدناه تقديرات ولا يُقيد شيء.'),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _monthCard(Map m, String mode, String pctStr) {
    final month = '${m['month']}';
    final settlement = m['settlement'] is Map ? m['settlement'] as Map : null;
    final sStatus = settlement == null ? null : '${settlement['status']}';
    final past = month.compareTo(_currentMonth()) < 0;
    final hasBaseline = m['baseline_2025'] != null;
    final canSettle = _isFinance && mode == 'baseline_2025' && past && (settlement == null || sStatus == 'rejected');

    final optionA = _option(
      title: '(أ) فوق إيرادات 2025',
      active: mode == 'baseline_2025',
      rows: [
        ('المحصّل (حصة الماء)', formatIqd(asNum(m['water_collected']))),
        ('أساس نفس الشهر 2025', hasBaseline ? formatIqd(asNum(m['baseline_2025'])) : 'لم تُدخل'),
        ('الزيادة', m['above_baseline'] == null ? '-' : formatIqd(asNum(m['above_baseline']))),
        ('حصة الشركة $pctStr%', m['estimate_baseline_2025'] == null ? '-' : formatIqd(asNum(m['estimate_baseline_2025']))),
      ],
    );
    final optionB = _option(
      title: '(ب) زيادة كل منزل',
      active: mode == 'per_house',
      rows: [
        ('مجموع الزيادة', formatIqd(asNum(m['per_house_increase']))),
        ('حصة الشركة $pctStr%', formatIqd(asNum(m['estimate_per_house']))),
        ('وصولات لها فاتورة سابقة',
            '${pctText(m['coverage'])} (${formatNumber(asNum(m['receipts_with_previous_bill']))}/${formatNumber(asNum(m['receipts']))})'),
        ('المقيّد فعلاً', formatIqd(asNum(m['booked_per_house']))),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(_monthLabel(month), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Text('${formatNumber(asNum(m['receipts']))} وصل', style: const TextStyle(color: Colors.grey)),
            if (!past) ...[const SizedBox(width: 8), const StatusChip('الشهر الجاري', Colors.blueGrey)],
          ]),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, c) {
            if (c.maxWidth >= 560) {
              return IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: optionA),
                  const SizedBox(width: 8),
                  Expanded(child: optionB),
                ]),
              );
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [optionA, const SizedBox(height: 8), optionB]);
          }),
          if (settlement != null || canSettle) const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (settlement != null) ...[
                StatusChip('التسوية: ${_settlementLabels[sStatus] ?? sStatus}', _settlementColor(sStatus ?? '')),
                Text(formatIqd(asNum(settlement['amount'])), style: const TextStyle(fontWeight: FontWeight.bold)),
                if (settlement['decided_at'] != null)
                  Text('قُرّرت ${formatDate(settlement['decided_at'])}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
              if (canSettle)
                hasBaseline
                    ? ElevatedButton.icon(
                        onPressed: () => _settle(month, asNum(m['estimate_baseline_2025'])),
                        icon: const Icon(Icons.send),
                        label: const Text('طلب التسوية'),
                      )
                    : const Text('أدخل إيرادات نفس الشهر من 2025 أولاً لطلب التسوية',
                        style: TextStyle(fontSize: 12, color: Colors.orange)),
            ],
          ),
        ]),
      ),
    );
  }

  Widget _option({required String title, required bool active, required List<(String, String)> rows}) {
    final color = active ? Colors.indigo : Colors.grey;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: active ? Colors.indigo.withValues(alpha: 0.06) : null,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: active ? 0.8 : 0.3), width: active ? 2 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: active ? Colors.indigo : null))),
          if (active) const StatusChip('الصيغة المعتمدة', Colors.indigo),
        ]),
        const SizedBox(height: 6),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Expanded(child: Text(r.$1, style: const TextStyle(fontSize: 13, color: Colors.grey))),
              Text(r.$2, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: r.$2 == 'لم تُدخل' ? Colors.orange : null)),
            ]),
          ),
      ]),
    );
  }

  Widget _baselineRow(String month, Map<String, Map> baselines) {
    final b = baselines[month];
    return ListTile(
      dense: true,
      title: Text(_monthLabel(month)),
      subtitle: b == null
          ? null
          : Text(
              [
                if (b['note'] != null && '${b['note']}'.isNotEmpty) '${b['note']}',
                'آخر تعديل ${formatDate(b['updated_at'])}',
              ].join(' | '),
              style: const TextStyle(fontSize: 11),
            ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(b == null ? 'لم تُدخل' : formatIqd(asNum(b['amount'])),
            style: TextStyle(fontWeight: FontWeight.bold, color: b == null ? Colors.orange : null)),
        if (_canEditBaselines)
          IconButton(
            tooltip: b == null ? 'إدخال' : 'تعديل',
            icon: Icon(b == null ? Icons.add_circle_outline : Icons.edit, size: 20),
            onPressed: () => _editBaseline(month, b),
          ),
      ]),
    );
  }
}
