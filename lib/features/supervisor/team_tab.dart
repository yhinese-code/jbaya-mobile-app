import 'package:flutter/material.dart';

import '../../core/api_client.dart';

/// Team activity today. Deliberately shows counts only (no money) so the cash reconciliation stays blind.
class TeamTab extends StatefulWidget {
  const TeamTab({super.key});

  @override
  State<TeamTab> createState() => _TeamTabState();
}

class _TeamTabState extends State<TeamTab> {
  List<Map<String, dynamic>> _team = [];
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
      final res = await ApiClient.instance.get('/supervisor/team');
      if (!mounted) return;
      setState(() {
        _team = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _ago(String? iso) {
    final t = DateTime.tryParse(iso ?? '');
    if (t == null) return 'لا يوجد نشاط';
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 1) return 'الآن';
    if (d.inMinutes < 60) return 'قبل ${d.inMinutes} دقيقة';
    if (d.inHours < 24) return 'قبل ${d.inHours} ساعة';
    return 'قبل ${d.inDays} يوم';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    if (_team.isEmpty) return const Center(child: Text('لا يوجد جباة ضمن فريقك'));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _team.length,
        itemBuilder: (context, i) {
          final t = _team[i];
          final sos = (t['open_sos'] as num? ?? 0) > 0;
          final master = (t['master_uses_today'] as num? ?? 0);
          return Card(
            color: sos ? Colors.red.shade50 : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: sos ? Colors.red : Colors.teal.shade50,
                        child: Icon(sos ? Icons.sos : Icons.person, color: sos ? Colors.white : Colors.teal),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${t['employee_code']} - ${t['full_name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('${t['sector_name'] ?? ''} | آخر نشاط: ${_ago(t['last_activity'] as String?)}',
                                style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _chip('وصولات اليوم', t['receipts_today'], Colors.green),
                      _chip('تسجيلات اليوم', t['registrations_today'], Colors.blue),
                      _chip('بانتظار التسليم', t['open_receipts'], Colors.teal),
                      if ((t['bills_in_review'] as num? ?? 0) > 0) _chip('قيد المراجعة', t['bills_in_review'], Colors.orange),
                      if (master > 0) _chip('الرمز الرئيسي', master, master >= 3 ? Colors.red : Colors.orange),
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

  Widget _chip(String label, dynamic value, Color color) {
    return Chip(
      label: Text('$label: $value', style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold)),
      backgroundColor: color.withValues(alpha: 0.08),
      side: BorderSide(color: color.withValues(alpha: 0.3)),
      visualDensity: VisualDensity.compact,
    );
  }
}
