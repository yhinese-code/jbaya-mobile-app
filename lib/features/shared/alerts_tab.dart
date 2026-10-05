import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';

/// SOS alerts. Supervisors see their team; Command sees everyone. Auto-refreshes every 20 seconds.
class AlertsTab extends StatefulWidget {
  const AlertsTab({super.key});

  @override
  State<AlertsTab> createState() => _AlertsTabState();
}

class _AlertsTabState extends State<AlertsTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final res = await ApiClient.instance.get('/alerts');
      if (!mounted) return;
      setState(() {
        _items = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  Future<void> _act(Map<String, dynamic> a, String action) async {
    try {
      await ApiClient.instance.post('/alerts/${a['id']}', {'action': action});
      if (mounted) _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    if (_items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_user, color: Colors.green, size: 48),
            SizedBox(height: 8),
            Text('لا توجد نداءات استغاثة مفتوحة'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final a = _items[i];
          final open = a['status'] == 'open';
          final t = DateTime.tryParse((a['created_at'] ?? '').toString())?.toLocal();
          final time = t == null ? '' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
          final hasGps = a['lat'] != null && a['lng'] != null;
          return Card(
            color: open ? Colors.red.shade50 : null,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: open ? Colors.red : Colors.grey.shade300, width: open ? 2 : 1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.sos, color: open ? Colors.red : Colors.grey),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('${a['employee_code']} - ${a['full_name']}',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                      Text(time),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('${a['sector_name'] ?? ''}${a['note'] != null ? ' | ${a['note']}' : ''}'),
                  Text(
                    hasGps
                        ? 'الموقع: ${a['lat']}, ${a['lng']}${a['gps_accuracy_m'] != null ? ' (دقة ${(a['gps_accuracy_m'] as num).round()} م)' : ''}'
                        : 'الموقع غير متوفر',
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (!open)
                    Text('تم الاستلام بواسطة ${a['acknowledged_by'] ?? '-'}', style: const TextStyle(fontSize: 12, color: Colors.green)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (open)
                        ElevatedButton(
                          onPressed: () => _act(a, 'acknowledge'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                          child: const Text('استلام والتحرك'),
                        ),
                      OutlinedButton(onPressed: () => _act(a, 'close'), child: const Text('إغلاق (تمت المعالجة)')),
                      if (hasGps)
                        SelectableText('https://maps.google.com/?q=${a['lat']},${a['lng']}',
                            style: const TextStyle(fontSize: 12, color: Colors.blue)),
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
