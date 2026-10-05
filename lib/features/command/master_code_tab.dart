import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';

/// Rotating master code (changes every 10 minutes). Visible to the Command role only.
/// Every use by a collector is listed below with its reason.
class MasterCodeTab extends StatefulWidget {
  const MasterCodeTab({super.key});

  @override
  State<MasterCodeTab> createState() => _MasterCodeTabState();
}

class _MasterCodeTabState extends State<MasterCodeTab> {
  String? _code;
  int _secondsLeft = 0;
  int _windowSeconds = 600;
  String? _error;
  List<Map<String, dynamic>> _uses = [];
  List<Map<String, dynamic>> _perCollector = [];
  Timer? _ticker;
  Timer? _usesTimer;

  @override
  void initState() {
    super.initState();
    _fetchCode();
    _fetchUses();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _usesTimer = Timer.periodic(const Duration(seconds: 60), (_) => _fetchUses());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _usesTimer?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted || _code == null) return;
    if (_secondsLeft <= 1) {
      setState(() => _secondsLeft = 0);
      _fetchCode();
    } else {
      setState(() => _secondsLeft--);
    }
  }

  Future<void> _fetchCode() async {
    try {
      final res = await ApiClient.instance.get('/command/master-code');
      if (!mounted) return;
      setState(() {
        _code = res['code'] as String;
        _secondsLeft = (asNum(res['seconds_remaining']) ?? 0).toInt();
        _windowSeconds = (asNum(res['window_seconds']) ?? 600).toInt();
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _fetchUses() async {
    try {
      final res = await ApiClient.instance.get('/command/master-code/uses?days=7');
      if (!mounted) return;
      setState(() {
        _uses = (res['uses'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _perCollector = (res['per_collector'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      });
    } on ApiException catch (_) {
      // the code panel already shows permission errors
    }
  }

  String _mmss(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _codeCard(),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(
                child: Text('سجل استخدام الرمز الرئيسي (آخر 7 أيام)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              IconButton(onPressed: _fetchUses, icon: const Icon(Icons.refresh)),
            ],
          ),
          if (_perCollector.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _perCollector
                  .map((c) => Chip(
                        avatar: const Icon(Icons.person, size: 18),
                        label: Text('${c['employee_code']}: ${c['uses']} مرة'),
                        backgroundColor: (asNum(c['uses']) ?? 0) >= 3 ? Colors.red.shade50 : Colors.grey.shade100,
                      ))
                  .toList(),
            ),
          const SizedBox(height: 10),
          if (_uses.isEmpty)
            const Padding(padding: EdgeInsets.all(20), child: Center(child: Text('لم يُستخدم الرمز الرئيسي خلال هذه الفترة')))
          else
            Card(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('الوقت')),
                    DataColumn(label: Text('الجابي')),
                    DataColumn(label: Text('العقار')),
                    DataColumn(label: Text('الغرض')),
                    DataColumn(label: Text('المبلغ')),
                    DataColumn(label: Text('السبب')),
                  ],
                  rows: _uses.map((u) {
                    final t = DateTime.tryParse((u['used_at'] ?? '').toString())?.toLocal();
                    final time = t == null
                        ? '-'
                        : '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
                            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
                    return DataRow(cells: [
                      DataCell(Text(time)),
                      DataCell(Text('${u['collector_code']}')),
                      DataCell(Text('${u['property_code']}')),
                      DataCell(Text(u['purpose'] == 'payment' ? 'دفع' : 'تسجيل')),
                      DataCell(Text(u['total_amount'] == null ? '-' : formatIqd(asNum(u['total_amount'])))),
                      DataCell(SizedBox(width: 260, child: Text('${u['reason']}'))),
                    ]);
                  }).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _codeCard() {
    if (_error != null) {
      return Card(
        color: Colors.red.shade50,
        child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 16))),
      );
    }
    if (_code == null) {
      return const Card(child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())));
    }
    final progress = _windowSeconds == 0 ? 0.0 : _secondsLeft / _windowSeconds;
    final urgent = _secondsLeft < 60;
    return Card(
      color: const Color(0xFF1B3B6F),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            const Text('الرمز الرئيسي الحالي', style: TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 8),
            SelectableText(
              _code!,
              style: const TextStyle(color: Colors.white, fontSize: 56, fontWeight: FontWeight.bold, letterSpacing: 12),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.white24,
              color: urgent ? Colors.orange : Colors.greenAccent,
            ),
            const SizedBox(height: 8),
            Text('يتغير خلال ${_mmss(_secondsLeft)}',
                style: TextStyle(color: urgent ? Colors.orange : Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text(
              'يُعطى للجابي فقط عند تعذر وصول رمز الواتساب للمواطن. كل استخدام يُسجَّل مع السبب ويُحسب في تقييم المخاطر.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
