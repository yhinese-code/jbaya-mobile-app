import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/theme.dart';

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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.bad));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    // also shown inside Command's dark theme: text colours come from the theme here, not from AppColors.ink
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 44, color: AppColors.faint),
            const SizedBox(height: Gap.md),
            const Text('تعذر تحميل الاستغاثات', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: Gap.xs),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.bad)),
            const SizedBox(height: Gap.lg),
            OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
          ]),
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_user, color: AppColors.good, size: 44),
            SizedBox(height: Gap.md),
            Text('لا توجد نداءات استغاثة مفتوحة', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            SizedBox(height: Gap.xs),
            Text('أي نداء من الميدان يظهر هنا فوراً', style: TextStyle(color: AppColors.muted)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(Gap.md),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final a = _items[i];
          final open = a['status'] == 'open';
          final t = DateTime.tryParse((a['created_at'] ?? '').toString())?.toLocal();
          final time = t == null ? '' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
          final hasGps = a['lat'] != null && a['lng'] != null;
          return AppCard(
            accent: open ? AppColors.bad : null,
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.sos, color: open ? AppColors.bad : AppColors.muted),
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
                    Text('تم الاستلام بواسطة ${a['acknowledged_by'] ?? '-'}', style: const TextStyle(fontSize: 12, color: AppColors.good)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: Gap.sm,
                    runSpacing: Gap.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (open)
                        ElevatedButton(
                          onPressed: () => _act(a, 'acknowledge'),
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.bad, foregroundColor: Colors.white),
                          child: const Text('استلام والتحرك'),
                        ),
                      OutlinedButton(onPressed: () => _act(a, 'close'), child: const Text('إغلاق (تمت المعالجة)')),
                      if (hasGps)
                        SelectableText('https://maps.google.com/?q=${a['lat']},${a['lng']}',
                            style: const TextStyle(fontSize: 12, color: AppColors.info)),
                    ],
                  ),
                ],
              ),
          );
        },
      ),
    );
  }
}
