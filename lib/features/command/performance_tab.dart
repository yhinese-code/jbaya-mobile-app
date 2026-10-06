import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import 'cc_widgets.dart';

/// Sector progress (coverage of the collection cycle) and the collector leaderboard with risk signals.
class PerformanceTab extends StatefulWidget {
  const PerformanceTab({super.key});

  @override
  State<PerformanceTab> createState() => _PerformanceTabState();
}

class _PerformanceTabState extends State<PerformanceTab> {
  List<Map<String, dynamic>> _sectors = [];
  List<Map<String, dynamic>> _board = [];
  int _days = 1;
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
      final res = await Future.wait([
        ApiClient.instance.get('/command/sectors'),
        ApiClient.instance.get('/command/leaderboard?days=$_days'),
      ]);
      if (!mounted) return;
      setState(() {
        _sectors = (res[0] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _board = (res[1] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
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
    if (_loading && _sectors.isEmpty) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: CC.danger)),
          const Text('تقدم القواطع (دورة الجباية)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: CC.text)),
          const SizedBox(height: 10),
          Wrap(spacing: 12, runSpacing: 12, children: _sectors.map(_sectorCard).toList()),
          const SizedBox(height: 24),
          Row(
            children: [
              const Expanded(
                child: Text('ترتيب الجباة ومؤشرات المخاطر', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: CC.text)),
              ),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('اليوم')),
                  ButtonSegment(value: 7, label: Text('7 أيام')),
                  ButtonSegment(value: 30, label: Text('30 يوم')),
                ],
                selected: {_days},
                onSelectionChanged: (s) {
                  setState(() => _days = s.first);
                  _load();
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(color: CC.panel, borderRadius: BorderRadius.circular(12), border: Border.all(color: CC.border)),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('#')),
                  DataColumn(label: Text('الجابي')),
                  DataColumn(label: Text('القاطع')),
                  DataColumn(label: Text('المحصّل'), numeric: true),
                  DataColumn(label: Text('وصولات'), numeric: true),
                  DataColumn(label: Text('تسجيلات'), numeric: true),
                  DataColumn(label: Text('تقديرات'), numeric: true),
                  DataColumn(label: Text('رمز رئيسي'), numeric: true),
                  DataColumn(label: Text('فرق نقدي'), numeric: true),
                  DataColumn(label: Text('أحداث أمنية'), numeric: true),
                ],
                rows: [
                  for (int i = 0; i < _board.length; i++) _boardRow(i + 1, _board[i]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'الأحداث الأمنية: خروج من القاطع، تزييف الموقع، حركة غير منطقية، رمز رئيسي خاطئ، محاولة تسجيل رقم موظف.',
            style: TextStyle(color: CC.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _sectorCard(Map<String, dynamic> s) {
    final coverage = (asNum(s['coverage']) ?? 0).toDouble();
    final color = coverage >= 0.8 ? CC.ok : (coverage >= 0.5 ? CC.warn : CC.danger);
    return Container(
      width: 300,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: CC.panel, borderRadius: BorderRadius.circular(12), border: Border.all(color: CC.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${s['code']} - ${s['name']}', style: const TextStyle(color: CC.text, fontWeight: FontWeight.bold)),
          Text('محلة ${s['mahalla'] ?? '-'} | ${s['collectors']} جابي', style: const TextStyle(color: CC.muted, fontSize: 12)),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('${(coverage * 100).toStringAsFixed(0)}%', style: TextStyle(color: color, fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              const Expanded(child: Text('من العقارات مدفوعة ضمن الدورة', style: TextStyle(color: CC.muted, fontSize: 12))),
            ],
          ),
          LinearProgressIndicator(value: coverage.clamp(0.0, 1.0), color: color, backgroundColor: color.withValues(alpha: 0.15), minHeight: 6),
          const SizedBox(height: 10),
          Text('العقارات ${s['properties']} | مدفوعة ${s['paid_in_cycle']} | مستحقة ${s['due']}', style: const TextStyle(color: CC.text, fontSize: 12)),
          Text('اليوم ${formatIqd(asNum(s['collected_today']))} | الشهر ${formatIqd(asNum(s['collected_month']))}',
              style: const TextStyle(color: CC.text, fontSize: 12)),
          Text('تسجيلات اليوم ${s['registered_today']}', style: const TextStyle(color: CC.muted, fontSize: 12)),
        ],
      ),
    );
  }

  DataRow _boardRow(int rank, Map<String, dynamic> r) {
    final security = (asNum(r['security_events']) ?? 0).toInt();
    final master = (asNum(r['master_code_receipts']) ?? 0).toInt();
    final diff = (asNum(r['cash_difference']) ?? 0).toDouble();
    Text danger(String v, bool bad) => Text(v, style: TextStyle(color: bad ? CC.danger : CC.text, fontWeight: bad ? FontWeight.bold : null));
    return DataRow(cells: [
      DataCell(Text('$rank')),
      DataCell(Text('${r['employee_code']} - ${r['full_name']}')),
      DataCell(Text('${r['sector_name'] ?? '-'}')),
      DataCell(Text(formatIqd(asNum(r['collected'])), style: const TextStyle(color: CC.ok, fontWeight: FontWeight.bold))),
      DataCell(Text('${r['receipts']}')),
      DataCell(Text('${r['registrations']}')),
      DataCell(Text('${r['estimates']}')),
      DataCell(danger('$master', master >= 3)),
      DataCell(danger(diff == 0 ? '0' : formatIqd(diff), diff != 0)),
      DataCell(danger('$security', security > 0)),
    ]);
  }
}
