import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';

/// Cash differences supervisors escalated, plus any left unresolved for more than 24 hours.
class EscalationsTab extends StatefulWidget {
  const EscalationsTab({super.key});

  @override
  State<EscalationsTab> createState() => _EscalationsTabState();
}

class _EscalationsTabState extends State<EscalationsTab> {
  List<Map<String, dynamic>> _items = [];
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
      final res = await ApiClient.instance.get('/command/escalations');
      if (!mounted) return;
      setState(() {
        _items = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.red)));
    if (_items.isEmpty) return const Center(child: Text('لا توجد فروقات نقدية محالة'));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final e = _items[i];
          final shortage = e['status'] == 'shortage';
          final overdue = e['resolution_status'] == 'pending';
          return Card(
            child: ListTile(
              leading: Icon(shortage ? Icons.trending_down : Icons.trending_up, color: shortage ? Colors.red : Colors.orange),
              title: Text('${shortage ? 'عجز' : 'زيادة'} ${formatIqd(asNum(e['difference']))} - ${e['collector_code']} ${e['collector_name']}'),
              subtitle: Text(
                'المشرف: ${e['supervisor_code']} | المعدود ${formatIqd(asNum(e['counted_cash']))} من ${formatIqd(asNum(e['expected_cash']))}\n'
                '${overdue ? 'لم يعالجه المشرف منذ أكثر من 24 ساعة' : 'محال من المشرف: ${e['resolution_note'] ?? ''}'}',
              ),
              isThreeLine: true,
            ),
          );
        },
      ),
    );
  }
}
