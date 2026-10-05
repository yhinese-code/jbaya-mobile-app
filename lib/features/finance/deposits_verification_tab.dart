import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../shared/photo_dialog.dart';

/// Finance checks each supervisor deposit against the bank statement: verify, or reject
/// (the cash then goes back on the supervisor's books until a valid deposit is made).
class DepositsVerificationTab extends StatefulWidget {
  const DepositsVerificationTab({super.key});

  @override
  State<DepositsVerificationTab> createState() => _DepositsVerificationTabState();
}

class _DepositsVerificationTabState extends State<DepositsVerificationTab> {
  String _status = 'pending';
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic>? _totals;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await ApiClient.instance.get('/finance/deposits?status=$_status');
      if (!mounted) return;
      setState(() {
        _items = (res['deposits'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _totals = Map<String, dynamic>.from(res['totals'] as Map);
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _decide(Map<String, dynamic> d, String action) async {
    final noteController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action == 'verify' ? 'تأكيد مطابقة الإيداع لكشف المصرف' : 'رفض الإيداع'),
        content: TextField(
          controller: noteController,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'الملاحظة (إلزامي)', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تأكيد')),
        ],
      ),
    );
    final note = noteController.text.trim();
    Future.delayed(const Duration(milliseconds: 400), noteController.dispose); // after the dialog's exit animation
    if (ok != true || !mounted) return;
    if (note.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يجب كتابة ملاحظة'), backgroundColor: Colors.red));
      return;
    }
    try {
      await ApiClient.instance.post('/finance/deposits/${d['id']}/decision', {'action': action, 'note': note});
      if (mounted) _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'pending', label: Text('بانتظار التدقيق')),
                  ButtonSegment(value: 'verified', label: Text('مُدقَّقة')),
                  ButtonSegment(value: 'rejected', label: Text('مرفوضة')),
                  ButtonSegment(value: 'all', label: Text('الكل')),
                ],
                selected: {_status},
                onSelectionChanged: (s) {
                  setState(() => _status = s.first);
                  _load();
                },
              ),
              if (_totals != null) ...[
                Chip(label: Text('بانتظار التدقيق: ${_totals!['pending_count']} | ${formatIqd(asNum(_totals!['pending_amount']))}')),
                Chip(label: Text('إجمالي المُدقَّق: ${formatIqd(asNum(_totals!['verified_amount']))}')),
              ],
            ],
          ),
        ),
        Expanded(child: _list()),
      ],
    );
  }

  Widget _list() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    if (_items.isEmpty) return const Center(child: Text('لا توجد إيداعات'));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final d = _items[i];
          final diff = asNum(d['difference']) ?? 0;
          final collectorDiff = asNum(d['collector_differences']) ?? 0;
          final t = DateTime.tryParse((d['created_at'] ?? '').toString())?.toLocal();
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('${formatIqd(asNum(d['amount']))} - ${d['bank_name']}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                      ),
                      if (t != null) Text('${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}'),
                    ],
                  ),
                  Text('المشرف: ${d['supervisor_code']} - ${d['supervisor_name']} | وصل رقم ${d['slip_number']}'),
                  Text('النقد المستلم من الجباة: ${formatIqd(asNum(d['expected_amount']))} (${d['reconciliations']} مطابقة)'),
                  if (diff != 0)
                    Text('فرق الإيداع عن النقد المستلم: ${formatIqd(diff)}',
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                  if (collectorDiff != 0)
                    Text('فروقات الجباة ضمن هذا الإيداع: ${formatIqd(collectorDiff)}', style: const TextStyle(color: Colors.orange)),
                  if (d['finance_note'] != null) Text('ملاحظة المالية: ${d['finance_note']}', style: const TextStyle(color: Colors.grey)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => showEvidencePhoto(context, '/finance/deposits/${d['id']}/slip', title: 'وصل الإيداع ${d['slip_number']}'),
                        icon: const Icon(Icons.receipt),
                        label: const Text('صورة الوصل'),
                      ),
                      if (d['status'] == 'pending') ...[
                        ElevatedButton(
                          onPressed: () => _decide(d, 'verify'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                          child: const Text('مطابق لكشف المصرف'),
                        ),
                        OutlinedButton(
                          onPressed: () => _decide(d, 'reject'),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                          child: const Text('رفض'),
                        ),
                      ],
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
