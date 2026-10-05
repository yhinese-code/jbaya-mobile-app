import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';

/// Supervisor portal: real blind cash reconciliation + review queue.
class SupervisorScreen extends StatelessWidget {
  const SupervisorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text('بوابة المشرف - ${Session.instance.fullName}', style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.orange.shade800,
          foregroundColor: Colors.white,
          actions: const [LogoutButton()],
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [
              Tab(icon: Icon(Icons.security), text: 'المطابقة النقدية'),
              Tab(icon: Icon(Icons.rule), text: 'مراجعة الفواتير'),
            ],
          ),
        ),
        body: const TabBarView(children: [_ReconciliationTab(), _ReviewsTab()]),
      ),
    );
  }
}

// ---------------------------------------------------------------- blind reconciliation

class _ReconciliationTab extends StatefulWidget {
  const _ReconciliationTab();

  @override
  State<_ReconciliationTab> createState() => _ReconciliationTabState();
}

class _ReconciliationTabState extends State<_ReconciliationTab> {
  List<Map<String, dynamic>> _collectors = [];
  String? _selected;
  final _cashController = TextEditingController();
  final _noteController = TextEditingController();
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _loadCollectors();
  }

  @override
  void dispose() {
    _cashController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _loadCollectors() async {
    try {
      final res = await ApiClient.instance.get('/supervisor/collectors');
      if (!mounted) return;
      setState(() => _collectors = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _submit() async {
    final cash = double.tryParse(_cashController.text.replaceAll(',', '').trim());
    if (_selected == null || cash == null) {
      setState(() => _error = 'يرجى اختيار الجابي وإدخال المبلغ المعدود');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.post('/supervisor/reconciliations', {
        'collector_code': _selected,
        'counted_cash': cash,
        'note': _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _result = Map<String, dynamic>.from(res as Map);
        _cashController.clear();
        _noteController.clear();
      });
      _loadCollectors();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.security, color: Colors.orange, size: 32),
                          SizedBox(width: 12),
                          Text('إجراء المطابقة (نهاية اليوم)', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'إجراء أمني: عُدّ النقد المستلم من الجابي وأدخله أولاً. لا يكشف النظام المبلغ المتوقع من الوصولات إلا بعد الإدخال.',
                        style: TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 24),
                      DropdownButtonFormField<String>(
                        initialValue: _selected,
                        decoration: const InputDecoration(labelText: 'الجابي', border: OutlineInputBorder(), prefixIcon: Icon(Icons.badge)),
                        items: _collectors
                            .map((c) => DropdownMenuItem(
                                  value: c['employee_code'] as String,
                                  child: Text('${c['employee_code']} - ${c['full_name']} (${c['open_receipts']} وصل)'),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() => _selected = v),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _cashController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'المبلغ النقدي المستلم فعلياً (د.ع)',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.money),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _noteController,
                        decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)', border: OutlineInputBorder()),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: _loading ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                        ),
                        child: const Text('كشف الحساب وإغلاق الصندوق', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ),
              if (_result != null) _resultCard(_result!),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resultCard(Map<String, dynamic> r) {
    final status = r['status'];
    final color = status == 'matched' ? Colors.green : (status == 'shortage' ? Colors.red : Colors.orange);
    final label = status == 'matched' ? 'مطابق' : (status == 'shortage' ? 'عجز' : 'زيادة');
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
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- review queue

class _ReviewsTab extends StatefulWidget {
  const _ReviewsTab();

  @override
  State<_ReviewsTab> createState() => _ReviewsTabState();
}

class _ReviewsTabState extends State<_ReviewsTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.get('/supervisor/reviews');
      if (!mounted) return;
      setState(() => _items = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _decide(Map<String, dynamic> bill, String action, String title) async {
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: noteController,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'السبب / الملاحظة (إلزامي)', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تأكيد')),
        ],
      ),
    );
    final note = noteController.text.trim();
    noteController.dispose();
    if (confirmed != true) return;
    if (note.length < 3) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يجب كتابة سبب'), backgroundColor: Colors.red));
      }
      return;
    }
    try {
      await ApiClient.instance.post('/supervisor/bills/${bill['id']}/decision', {'action': action, 'note': note});
      if (!mounted) return;
      _load();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: Colors.red));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(children: const [SizedBox(height: 120), Center(child: Text('لا توجد فواتير بانتظار المراجعة'))]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final b = _items[i];
          final blocked = b['status'] == 'blocked_review';
          final labels = (b['flag_labels'] as List? ?? []).map((e) => e.toString()).toList();
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${b['property_code']} - ${b['citizen_name']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text('${b['address']} | الجابي: ${b['collector_code']}'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: labels
                        .map((l) => Chip(
                              label: Text(l, style: const TextStyle(fontSize: 12)),
                              backgroundColor: blocked ? Colors.red.shade50 : Colors.orange.shade50,
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 6),
                  if (b['previous_reading'] != null)
                    Text('القراءة السابقة: ${formatNumber(asNum(b['previous_reading']), decimals: 1)}  |  '
                        'الحالية: ${b['current_reading'] == null ? '-' : formatNumber(asNum(b['current_reading']), decimals: 1)}'),
                  Text('المبلغ التقديري: ${formatIqd(asNum(b['total_amount']))} (${b['period_days']} يوم)'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (!blocked)
                        ElevatedButton(
                          onPressed: () => _decide(b, 'approve', 'الموافقة على التقدير'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                          child: const Text('موافقة'),
                        ),
                      if (blocked)
                        ElevatedButton(
                          onPressed: () => _decide(b, 'rebaseline', 'العداد مُبدَّل: اعتماد القراءة الجديدة كأساس وجباية تقديرية'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                          child: const Text('عداد مُبدَّل (أساس جديد)'),
                        ),
                      OutlinedButton(
                        onPressed: () => _decide(b, 'reject', 'رفض الفاتورة'),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                        child: const Text('رفض'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
