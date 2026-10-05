import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../shared/photo_dialog.dart';

// ---------------------------------------------------------------- review queue

class ReviewsTab extends StatefulWidget {
  const ReviewsTab({super.key});

  @override
  State<ReviewsTab> createState() => _ReviewsTabState();
}

class _ReviewsTabState extends State<ReviewsTab> {
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
    Future.delayed(const Duration(milliseconds: 400), noteController.dispose); // after the dialog's exit animation
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
                  if (b['ocr_reading'] != null)
                    Text('قراءة الكاميرا (OCR): ${formatNumber(asNum(b['ocr_reading']), decimals: 1)}',
                        style: const TextStyle(color: Colors.teal)),
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
                      if (b['has_photo'] == true)
                        OutlinedButton.icon(
                          onPressed: () => showEvidencePhoto(context, '/bills/${b['id']}/photo', title: 'صورة العداد - ${b['property_code']}'),
                          icon: const Icon(Icons.photo),
                          label: const Text('صورة العداد'),
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
