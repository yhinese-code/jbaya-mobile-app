import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import 'cc_widgets.dart';

/// Real receipts log (latest first) with search. Master-code receipts and flagged bills are highlighted.
class ReceiptsLogTab extends StatefulWidget {
  const ReceiptsLogTab({super.key});

  @override
  State<ReceiptsLogTab> createState() => _ReceiptsLogTabState();
}

class _ReceiptsLogTabState extends State<ReceiptsLogTab> {
  List<Map<String, dynamic>> _rows = [];
  String _q = '';
  bool _onlyFlagged = false;
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
      final res = await ApiClient.instance.get('/command/receipts?limit=500');
      if (!mounted) return;
      setState(() {
        _rows = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _flagged(Map<String, dynamic> r) =>
      r['verification_method'] == 'master_code' || ((r['flags'] as List?)?.isNotEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toUpperCase();
    final rows = _rows.where((r) {
      if (_onlyFlagged && !_flagged(r)) return false;
      if (q.isEmpty) return true;
      return '${r['receipt_no']} ${r['property_code']} ${r['collector_code']}'.toUpperCase().contains(q);
    }).toList();
    final total = rows.fold<double>(0, (s, r) => s + ((asNum(r['total_amount']) ?? 0).toDouble()));

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  onChanged: (v) => setState(() => _q = v),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: 'رقم الوصل أو العقار أو الجابي',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              FilterChip(label: const Text('المؤشَّرة فقط'), selected: _onlyFlagged, onSelected: (v) => setState(() => _onlyFlagged = v)),
              Chip(label: Text('${rows.length} وصل | ${formatIqd(total)}')),
              IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'تحديث'),
            ],
          ),
          const SizedBox(height: 12),
          if (_error != null) Text(_error!, style: const TextStyle(color: CC.danger)),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Container(
                    decoration: BoxDecoration(color: CC.panel, borderRadius: BorderRadius.circular(12), border: Border.all(color: CC.border)),
                    child: SingleChildScrollView(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('رقم الوصل')),
                            DataColumn(label: Text('الوقت')),
                            DataColumn(label: Text('العقار')),
                            DataColumn(label: Text('الجابي')),
                            DataColumn(label: Text('رسوم الاستهلاك'), numeric: true),
                            DataColumn(label: Text('أجور الشركة'), numeric: true),
                            DataColumn(label: Text('المجموع'), numeric: true),
                            DataColumn(label: Text('التوثيق')),
                            DataColumn(label: Text('مؤشرات')),
                          ],
                          rows: rows.map((r) {
                            final t = DateTime.tryParse('${r['issued_at']}')?.toLocal();
                            final master = r['verification_method'] == 'master_code';
                            final flags = ((r['flags'] as List?) ?? []).join('، ');
                            return DataRow(
                              color: WidgetStatePropertyAll(_flagged(r) ? CC.warn.withValues(alpha: 0.08) : null),
                              cells: [
                                DataCell(Text('${r['receipt_no']}', style: const TextStyle(color: CC.accent, fontWeight: FontWeight.bold))),
                                DataCell(Text(t == null ? '-' : '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}')),
                                DataCell(Text('${r['property_code']}')),
                                DataCell(Text('${r['collector_code']}')),
                                DataCell(Text(formatIqd(asNum(r['gov_amount'])))),
                                DataCell(Text(formatIqd(asNum(r['company_fee'])))),
                                DataCell(Text(formatIqd(asNum(r['total_amount'])), style: const TextStyle(fontWeight: FontWeight.bold))),
                                DataCell(Text(master ? 'رمز رئيسي' : 'OTP المواطن', style: TextStyle(color: master ? CC.warn : CC.ok))),
                                DataCell(Text(flags.isEmpty ? '-' : flags, style: const TextStyle(fontSize: 12))),
                              ],
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
