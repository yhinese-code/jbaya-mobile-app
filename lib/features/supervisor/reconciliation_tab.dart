import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';

/// Blind cash reconciliation: count the notes by denomination, submit, and only then see the expected amount.
/// Any difference must be resolved (collector pays / salary deduction / escalate) before the cash can be deposited.
class ReconciliationTab extends StatefulWidget {
  const ReconciliationTab({super.key});

  @override
  State<ReconciliationTab> createState() => _ReconciliationTabState();
}

const _notes = [50000, 25000, 10000, 5000, 1000, 500, 250];

class _ReconciliationTabState extends State<ReconciliationTab> {
  List<Map<String, dynamic>> _collectors = [];
  List<Map<String, dynamic>> _history = [];
  String? _selected;
  final Map<int, TextEditingController> _counts = {for (final n in _notes) n: TextEditingController()};
  final _noteController = TextEditingController();
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    for (final c in _counts.values) {
      c.addListener(() => setState(() {}));
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in _counts.values) {
      c.dispose();
    }
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/supervisor/collectors'),
        ApiClient.instance.get('/supervisor/reconciliations'),
      ]);
      if (!mounted) return;
      setState(() {
        _collectors = (res[0] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _history = (res[1] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  int _count(int note) => int.tryParse(_counts[note]!.text.trim()) ?? 0;

  int get _total => _notes.fold(0, (sum, n) => sum + n * _count(n));

  Future<void> _submit() async {
    if (_selected == null) {
      setState(() => _error = 'يرجى اختيار الجابي');
      return;
    }
    if (_counts.values.any((c) => c.text.trim().isNotEmpty && int.tryParse(c.text.trim()) == null)) {
      setState(() => _error = 'عدد الأوراق يجب أن يكون رقماً صحيحاً');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد المبلغ المعدود'),
        content: Text('المجموع المعدود: ${formatIqd(_total)}\nلا يمكن تعديل المطابقة بعد الإرسال.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إرسال')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.post('/supervisor/reconciliations', {
        'collector_code': _selected,
        'denominations': {for (final n in _notes) if (_count(n) > 0) '$n': _count(n)},
        'note': _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _result = Map<String, dynamic>.from(res as Map);
        for (final c in _counts.values) {
          c.clear();
        }
        _noteController.clear();
        _selected = null;
      });
      _load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resolve(int recId, String status) async {
    final options = <String, String>{
      if (status == 'shortage') 'collector_paid': 'دفع الجابي الفرق نقداً الآن',
      if (status == 'shortage') 'salary_deduction': 'يُستقطع من راتب الجابي',
      if (status == 'surplus') 'deposit_surplus': 'يُودَع الفائض ويُحقَّق في مصدره',
      'escalate': 'إحالة إلى القيادة للتحقيق',
    };
    String action = options.keys.first;
    final noteController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(status == 'shortage' ? 'معالجة العجز' : 'معالجة الزيادة'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: options.entries
                    .map((e) => ChoiceChip(
                          label: Text(e.value),
                          selected: action == e.key,
                          onSelected: (_) => setDialog(() => action = e.key),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'التفاصيل (إلزامي)', border: OutlineInputBorder()),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تأكيد')),
          ],
        ),
      ),
    );
    final note = noteController.text.trim();
    Future.delayed(const Duration(milliseconds: 400), noteController.dispose); // after the dialog's exit animation
    if (ok != true || !mounted) return;
    if (note.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يجب كتابة التفاصيل'), backgroundColor: Colors.red));
      return;
    }
    try {
      final res = await ApiClient.instance.post('/supervisor/reconciliations/$recId/resolve', {'action': action, 'note': note});
      if (!mounted) return;
      setState(() {
        if (_result?['reconciliation_id'] == recId) _result!['resolution_status'] = res['resolution_status'];
      });
      _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _history.where((h) => h['resolution_status'] == 'pending').toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (pending.isNotEmpty) _pendingCard(pending),
                _countCard(),
                if (_result != null) _resultCard(_result!),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _countCard() {
    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.security, color: Colors.orange, size: 30),
                SizedBox(width: 10),
                Expanded(child: Text('المطابقة النقدية العمياء', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'عُدّ الأوراق النقدية المستلمة من الجابي وأدخل عدد كل فئة. لا يُكشف المبلغ المتوقع إلا بعد الإرسال.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: ValueKey('collector-${_result?['reconciliation_id']}'),
              initialValue: _selected,
              decoration: const InputDecoration(labelText: 'الجابي', border: OutlineInputBorder(), prefixIcon: Icon(Icons.badge)),
              items: _collectors
                  .map((c) {
                    final open = (asNum(c['open_receipts']) ?? 0) > 0;
                    return DropdownMenuItem(
                      value: c['employee_code'] as String,
                      enabled: open,
                      child: Text(
                        open
                            ? '${c['employee_code']} - ${c['full_name']} (${c['open_receipts']} وصل)'
                            : '${c['employee_code']} - ${c['full_name']} (لا توجد وصولات للتسوية)',
                        style: open ? null : const TextStyle(color: Colors.grey),
                      ),
                    );
                  })
                  .toList(),
              onChanged: (v) => setState(() => _selected = v),
            ),
            const SizedBox(height: 16),
            Table(
              columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(2), 2: FlexColumnWidth(2)},
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                const TableRow(children: [
                  Padding(padding: EdgeInsets.all(6), child: Text('الفئة', style: TextStyle(fontWeight: FontWeight.bold))),
                  Padding(padding: EdgeInsets.all(6), child: Text('عدد الأوراق', style: TextStyle(fontWeight: FontWeight.bold))),
                  Padding(padding: EdgeInsets.all(6), child: Text('المجموع', style: TextStyle(fontWeight: FontWeight.bold))),
                ]),
                for (final n in _notes)
                  TableRow(children: [
                    Padding(padding: const EdgeInsets.all(6), child: Text(formatNumber(n))),
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: TextField(
                        controller: _counts[n],
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: '0'),
                      ),
                    ),
                    Padding(padding: const EdgeInsets.all(6), child: Text(formatNumber(n * _count(n)))),
                  ]),
              ],
            ),
            const Divider(height: 24),
            Text('المجموع المعدود: ${formatIqd(_total)}',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)', border: OutlineInputBorder()),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            ],
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loading ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
              ),
              child: const Text('كشف الحساب وإغلاق الصندوق', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(Map<String, dynamic> r) {
    final status = r['status'];
    final color = status == 'matched' ? Colors.green : (status == 'shortage' ? Colors.red : Colors.orange);
    final label = status == 'matched' ? 'مطابق' : (status == 'shortage' ? 'عجز' : 'زيادة');
    final needsAction = r['resolution_status'] == 'pending';
    return Card(
      color: color.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(side: BorderSide(color: color), borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('النتيجة: $label', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            const Divider(),
            Text('الجابي: ${r['collector_code']} - ${r['collector_name']}'),
            Text('عدد الوصولات: ${r['receipts_count']}'),
            Text('المبلغ المعدود: ${formatIqd(asNum(r['counted_cash']))}'),
            Text('المبلغ المتوقع من الوصولات: ${formatIqd(asNum(r['expected_cash']))}'),
            Text('الفرق: ${formatIqd(asNum(r['difference']))}', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
            if (needsAction) ...[
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => _resolve(r['reconciliation_id'] as int, status as String),
                style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
                child: const Text('معالجة الفرق (إلزامي قبل الإيداع)'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pendingCard(List<Map<String, dynamic>> pending) {
    return Card(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('فروقات بانتظار المعالجة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Text(
              'تم إغلاق صندوق هذا الجابي. لا تُعِد العدّ: اضغط "معالجة الفرق" واختر الإجراء المناسب.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            ...pending.map((h) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${h['collector_code']} - ${h['collector_name']}'),
                  subtitle: Text('${h['status'] == 'shortage' ? 'عجز' : 'زيادة'}: ${formatIqd(asNum(h['difference']))}'),
                  trailing: ElevatedButton(
                    onPressed: () => _resolve(h['id'] as int, h['status'] as String),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: h['status'] == 'shortage' ? Colors.red : Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('معالجة الفرق'),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}
