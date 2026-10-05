import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import 'collection_screen.dart';

/// Periodic collection list for the collector's sector (assigned by the server).
class RouteScreen extends StatefulWidget {
  const RouteScreen({super.key});

  @override
  State<RouteScreen> createState() => RouteScreenState();
}

class RouteScreenState extends State<RouteScreen> {
  List<Map<String, dynamic>> _properties = [];
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
      final res = await ApiClient.instance.get('/collector/route');
      final list = (res['properties'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      setState(() => _properties = list);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int _count(String color) => _properties.where((p) => p['status_color'] == color).length;

  Color _color(String c) => c == 'red' ? Colors.red : (c == 'yellow' ? Colors.orange : Colors.green);

  Future<void> _open(Map<String, dynamic> prop) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CollectionScreen(property: prop)),
    );
    if (changed == true || prop['open_bill_id'] != null) reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat('مكتمل (أخضر)', _count('green'), Colors.green),
              _stat('قيد النضوج (أصفر)', _count('yellow'), Colors.orange),
              _stat('مستحق فوراً (أحمر)', _count('red'), Colors.red),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            TextButton(onPressed: reload, child: const Text('إعادة المحاولة')),
          ],
        ),
      );
    }
    if (_properties.isEmpty) {
      return const Center(child: Text('لا توجد عقارات مسجلة في قاطعك بعد'));
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _properties.length,
        itemBuilder: (context, i) {
          final p = _properties[i];
          final color = _color((p['status_color'] ?? 'red').toString());
          final days = p['days_since_paid'];
          final openStatus = p['open_bill_status'];
          String subtitle = '${p['address']} | ${propertyClassLabels[p['property_class']] ?? ''}\n';
          subtitle += p['never_paid'] == true ? 'لم تتم الجباية بعد (زيارة أولى)' : 'آخر جباية قبل $days يوم';
          if (openStatus == 'pending_approval') subtitle += ' | بانتظار موافقة المشرف';
          if (openStatus == 'blocked_review') subtitle += ' | قيد مراجعة المشرف';
          if (openStatus == 'awaiting_otp') subtitle += ' | بانتظار رمز المواطن';
          return Card(
            elevation: 1,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: color.withValues(alpha: 0.5), width: 1.5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: ListTile(
              leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.1), child: Icon(Icons.home, color: color)),
              title: Text('${p['citizen_name']} (${p['property_code']})', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(subtitle),
              isThreeLine: true,
              trailing: p['status_color'] == 'green' && openStatus == null
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : ElevatedButton(
                      onPressed: () => _open(p),
                      style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
                      child: Text(openStatus != null ? 'متابعة' : 'بدء الجباية'),
                    ),
              onTap: () => _open(p),
            ),
          );
        },
      ),
    );
  }

  Widget _stat(String label, int value, Color color) {
    return Column(
      children: [
        Text('$value', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
