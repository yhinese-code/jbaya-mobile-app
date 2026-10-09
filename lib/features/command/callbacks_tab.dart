import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../shared/ui.dart';
import 'cc_widgets.dart';

const Map<String, String> _statusLabels = {
  'pending': 'لم يُتصل بعد',
  'confirmed': 'أكّد الدفع',
  'denied': 'أنكر الدفع',
  'wrong_amount': 'مبلغ مختلف',
  'no_answer': 'لم يرد',
};

Color _statusColor(String s) => switch (s) {
      'confirmed' => CC.ok,
      'denied' => CC.critical,
      'wrong_amount' => CC.danger,
      'no_answer' => CC.warn,
      _ => CC.muted,
    };

/// 'الاتصال العشوائي': each day a random sample of receipts; Command calls the citizen to confirm he really paid.
class CallbacksTab extends StatefulWidget {
  const CallbacksTab({super.key});

  @override
  State<CallbacksTab> createState() => _CallbacksTabState();
}

class _CallbacksTabState extends State<CallbacksTab> {
  DateTime _day = DateTime.now();
  List<Map> _items = const [];
  bool _loading = true;
  String? _error;
  final Set<int> _busy = {};

  bool get _isToday => apiDate(_day) == apiDate(DateTime.now());

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.get('/command/callbacks?day=${apiDate(_day)}');
      if (!mounted) return;
      final items = res is Map ? res['items'] : null;
      setState(() => _items = items is List ? items.whereType<Map>().toList() : const []);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
    );
    if (d == null || !mounted) return;
    _day = d;
    _load();
  }

  void _shiftDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(DateTime.now())) return;
    _day = next;
    _load();
  }

  Future<void> _record(Map item, String status) async {
    final id = asNum(item['id'])?.toInt();
    if (id == null) return;
    String? note;
    if (status == 'denied' || status == 'wrong_amount') {
      note = await askNote(
        context,
        status == 'denied' ? 'المواطن أنكر الدفع' : 'المواطن ذكر مبلغاً مختلفاً',
        required: true,
        label: 'ما قاله المواطن',
      );
      if (note == null) return;
    }
    if (!mounted) return;
    setState(() => _busy.add(id));
    final r = await runApi(
      context,
      () => ApiClient.instance.post('/command/callbacks/$id', {'status': status, 'note': note}),
      success: 'سُجّل: ${_statusLabels[status]}',
    );
    if (!mounted) return;
    setState(() => _busy.remove(id));
    if (r != null) _load();
  }

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final i in _items) {
      final s = '${i['status']}';
      counts[s] = (counts[s] ?? 0) + 1;
    }
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        _header(counts),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(children: [
              Text(_error!, style: const TextStyle(color: CC.danger)),
              TextButton(onPressed: _load, child: const Text('إعادة المحاولة')),
            ]),
          )
        else if (_items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: Text('لا اتصالات مخصصة لهذا اليوم', style: TextStyle(color: CC.muted))),
          )
        else
          ..._items.map(_card),
      ],
    );
  }

  Widget _header(Map<String, int> counts) {
    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: CC.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CC.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Icons.phone_callback, color: CC.accent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('الاتصال العشوائي بالمواطنين',
                style: TextStyle(color: CC.text, fontWeight: FontWeight.bold, fontSize: 17)),
          ),
          IconButton(
            tooltip: 'اليوم السابق',
            onPressed: _loading ? null : () => _shiftDay(-1),
            icon: const Icon(Icons.chevron_right, color: CC.text),
          ),
          TextButton.icon(
            onPressed: _loading ? null : _pickDay,
            icon: const Icon(Icons.calendar_today, size: 16),
            label: Text(_isToday ? 'اليوم ${apiDate(_day)}' : apiDate(_day)),
          ),
          IconButton(
            tooltip: 'اليوم التالي',
            onPressed: _loading || _isToday ? null : () => _shiftDay(1),
            icon: Icon(Icons.chevron_left, color: _isToday ? CC.muted : CC.text),
          ),
          IconButton(tooltip: 'تحديث', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh, color: CC.text)),
        ]),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(Gap.md),
          decoration: BoxDecoration(
            color: CC.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            'اتصل بالمواطن واسأله: هل دفعت {المبلغ} اليوم لموظف الجباية؟\n'
            'لا تذكر اسم الجابي ولا تلمّح إلى الجواب. سجّل ما قاله المواطن كما هو.',
            style: TextStyle(color: CC.text, fontSize: 14, height: 1.5),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _countChip('الكل', _items.length, CC.accent),
          for (final k in _statusLabels.keys) _countChip(_statusLabels[k]!, counts[k] ?? 0, _statusColor(k)),
        ]),
      ]),
    );
  }

  Widget _countChip(String label, int n, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text('$label: $n', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
    );
  }

  Widget _card(Map i) {
    final id = asNum(i['id'])?.toInt() ?? -1;
    final status = '${i['status']}';
    final color = _statusColor(status);
    final busy = _busy.contains(id);
    final phone = '${i['phone'] ?? ''}';
    final amount = iqd(i['total_amount']);
    final note = '${i['answer_note'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: CC.panel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: status == 'pending' ? CC.border : color.withValues(alpha: 0.6)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text('${i['citizen_name'] ?? '-'}',
                  style: const TextStyle(color: CC.text, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            _countLabel(i['status_label']?.toString() ?? _statusLabels[status] ?? status, color),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.phone, color: CC.accent, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                phone,
                textDirection: TextDirection.ltr,
                style: const TextStyle(color: CC.text, fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: 1.5),
              ),
            ),
            IconButton(
              tooltip: 'نسخ الرقم',
              icon: const Icon(Icons.copy, color: CC.muted, size: 18),
              onPressed: phone.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: phone));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('نُسخ الرقم')));
                    },
            ),
          ]),
          Text('اسأله: هل دفعت $amount اليوم لموظف الجباية؟', style: const TextStyle(color: CC.accent, fontSize: 13)),
          const SizedBox(height: 6),
          Wrap(spacing: 16, runSpacing: 4, children: [
            _fact(Icons.payments, 'المبلغ', amount, highlight: true),
            _fact(Icons.receipt, 'الوصل', '${i['receipt_no'] ?? '-'}'),
            _fact(Icons.schedule, 'الوقت', '${formatDate(i['issued_at'])} ${clock(i['issued_at']?.toString())}'),
            _fact(Icons.badge, 'الجابي', '${i['collector_name'] ?? '-'} (${i['collector_code'] ?? '-'})'),
            _fact(Icons.home, 'العقار', '${i['property_code'] ?? '-'}'),
            if (i['verification_method'] != null) _fact(Icons.verified_user, 'التحقق', '${i['verification_method']}'),
          ]),
          if ('${i['address'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${i['address']}', style: const TextStyle(color: CC.muted, fontSize: 12)),
            ),
          if (status != 'pending')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                [
                  if (note.isNotEmpty) 'قال المواطن: $note',
                  if (i['called_by'] != null) 'اتصل ${i['called_by']}',
                  if (i['called_at'] != null) clock(i['called_at']?.toString()),
                ].join(' | '),
                style: TextStyle(color: color, fontSize: 13),
              ),
            ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _action(i, 'confirmed', 'أكّد الدفع', Icons.check_circle, status, busy),
            _action(i, 'denied', 'أنكر الدفع', Icons.cancel, status, busy),
            _action(i, 'wrong_amount', 'مبلغ مختلف', Icons.price_change, status, busy),
            _action(i, 'no_answer', 'لم يرد', Icons.phone_missed, status, busy),
          ]),
        ]),
      ),
    );
  }

  Widget _countLabel(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12)),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
    );
  }

  Widget _fact(IconData icon, String label, String value, {bool highlight = false}) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 16, color: CC.muted),
      const SizedBox(width: 4),
      Text('$label: ', style: const TextStyle(color: CC.muted, fontSize: 13)),
      Text(value,
          style: TextStyle(
            color: highlight ? CC.warn : CC.text,
            fontSize: highlight ? 17 : 13,
            fontWeight: highlight ? FontWeight.bold : FontWeight.w500,
          )),
    ]);
  }

  Widget _action(Map item, String status, String label, IconData icon, String current, bool busy) {
    final color = _statusColor(status);
    final selected = current == status;
    return selected
        ? ElevatedButton.icon(
            onPressed: busy ? null : () => _record(item, status),
            style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
            icon: Icon(icon, size: 18),
            label: Text(label),
          )
        : OutlinedButton.icon(
            onPressed: busy ? null : () => _record(item, status),
            style: OutlinedButton.styleFrom(foregroundColor: color, side: BorderSide(color: color.withValues(alpha: 0.6))),
            icon: Icon(icon, size: 18),
            label: Text(label),
          );
  }
}
