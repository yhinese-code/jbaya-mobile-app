import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';

/// Today's receipts + any receipt not yet handed over to the supervisor.
class ReceiptsScreen extends StatefulWidget {
  const ReceiptsScreen({super.key});

  @override
  State<ReceiptsScreen> createState() => ReceiptsScreenState();
}

class ReceiptsScreenState extends State<ReceiptsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.get('/collector/receipts');
      if (!mounted) return;
      setState(() => _items = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
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
    if (_items.isEmpty) return const Center(child: Text('لا توجد وصولات اليوم'));
    final notHanded = _items.where((r) => r['handed_over'] != true).toList();
    final total = notHanded.fold<double>(0, (sum, r) => sum + (asNum(r['total_amount']) ?? 0));
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            color: Colors.teal.shade50,
            child: ListTile(
              leading: const Icon(Icons.account_balance_wallet, color: Colors.teal),
              title: Text('بانتظار التسليم للمشرف: ${notHanded.length} وصل'),
              subtitle: Text('المجموع: ${formatIqd(total)}'),
            ),
          ),
          ..._items.map((r) {
            final t = DateTime.tryParse((r['issued_at'] ?? '').toString())?.toLocal();
            final time = t == null ? '' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
            final handed = r['handed_over'] == true;
            return Card(
              child: ListTile(
                leading: Icon(handed ? Icons.check_circle : Icons.receipt_long, color: handed ? Colors.green : Colors.orange),
                title: Text('${r['receipt_no']} - ${r['citizen_name']}'),
                subtitle: Text('${r['property_code']} | $time${r['verification_method'] == 'master_code' ? ' | الرمز الرئيسي' : ''}'
                    '${handed ? ' | سُلّم' : ''}'),
                trailing: Text(formatIqd(asNum(r['total_amount'])), style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            );
          }),
        ],
      ),
    );
  }
}
