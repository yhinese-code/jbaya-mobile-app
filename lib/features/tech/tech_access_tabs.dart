import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../shared/ui.dart';
import 'tech_common.dart';

// ================================================================ devices

const Map<String, String> _deviceStatusLabels = {
  'pending': 'بانتظار الموافقة',
  'approved': 'معتمد',
  'rejected': 'مرفوض',
  'revoked': 'أُلغي اعتماده',
};

Color _deviceStatusColor(String s) {
  switch (s) {
    case 'approved':
      return Colors.green.shade700;
    case 'rejected':
      return Colors.red.shade700;
    case 'revoked':
      return Colors.grey.shade700;
    default:
      return Colors.orange.shade800;
  }
}

/// Device approvals: a new phone / PC waits here until the tech panel approves it.
class TechDevicesTab extends StatefulWidget {
  const TechDevicesTab({super.key});

  @override
  State<TechDevicesTab> createState() => _TechDevicesTabState();
}

class _TechDevicesTabState extends State<TechDevicesTab> {
  String _status = 'pending';

  static const _filters = {
    'pending': 'معلقة',
    'approved': 'معتمدة',
    'rejected': 'مرفوضة',
    'revoked': 'ملغاة',
    'all': 'الكل',
  };

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [for (final e in _filters.entries) ButtonSegment(value: e.key, label: Text(e.value))],
            selected: {_status},
            onSelectionChanged: (s) => setState(() => _status = s.first),
          ),
        ),
      ),
      Expanded(
        child: ApiView(
          path: '/tech/devices?status=$_status',
          builder: (context, data, reload) {
            final rows = ((data as List?) ?? const []).cast<Map>();
            return RefreshIndicator(
              onRefresh: reload,
              child: rows.isEmpty
                  ? ListView(children: const [EmptyNote('لا توجد أجهزة في هذه القائمة')])
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: rows.length,
                      itemBuilder: (context, i) => _DeviceCard(device: rows[i], onChanged: reload),
                    ),
            );
          },
        ),
      ),
    ]);
  }
}

class _DeviceCard extends StatelessWidget {
  final Map device;
  final Future<void> Function() onChanged;
  const _DeviceCard({required this.device, required this.onChanged});

  String get _path => '/tech/devices/${device['id']}/decision';

  Future<void> _approve(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ApiClient.instance.post(_path, {'action': 'approve'});
      messenger.showSnackBar(SnackBar(content: const Text('تمت الموافقة على الجهاز'), backgroundColor: Colors.green.shade700));
    } on ApiException catch (e) {
      final overLimit = e.statusCode == 409 && (e.message.contains('المسموح') || e.message.contains('الأقدم'));
      if (!overLimit) {
        messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: Colors.red.shade700));
        return;
      }
      if (!context.mounted) return;
      final ok = await confirm(
        context,
        'تجاوز حد الأجهزة',
        '${e.message}\n\nهل تريد الموافقة على هذا الجهاز وإلغاء اعتماد أقدم جهاز لهذا الموظف (تُنهى جلساته عليه)؟',
      );
      if (!ok || !context.mounted) return;
      await runApi(
        context,
        () => ApiClient.instance.post(_path, {'action': 'approve', 'replace_oldest': true}),
        success: 'تمت الموافقة واستُبدل الجهاز الأقدم',
      );
    }
    await onChanged();
  }

  Future<void> _reject(BuildContext context) async {
    final note = await askNote(context, 'رفض طلب الجهاز', label: 'سبب الرفض');
    if (note == null || !context.mounted) return;
    await runApi(
      context,
      () => ApiClient.instance.post(_path, {'action': 'reject', 'note': note.isEmpty ? null : note}),
      success: 'رُفض الطلب',
    );
    await onChanged();
  }

  Future<void> _revoke(BuildContext context) async {
    final note = await askNote(context, 'إلغاء اعتماد الجهاز (تُنهى جلساته)', required: true, label: 'السبب');
    if (note == null || !context.mounted) return;
    await runApi(
      context,
      () => ApiClient.instance.post(_path, {'action': 'revoke', 'note': note}),
      success: 'أُلغي اعتماد الجهاز',
    );
    await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final d = device;
    final status = txt(d['status'], 'pending');
    final approved = toInt(d['approved_count']);
    final limit = toInt(d['limit']);
    final full = limit > 0 && approved >= limit;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${txt(d['employee_code'])} - ${txt(d['full_name'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 6),
            StatusChip(_deviceStatusLabels[status] ?? status, _deviceStatusColor(status)),
          ]),
          InfoLine(Icons.badge, '${txt(d['role_label'])}  •  الأجهزة المعتمدة: $approved من $limit',
              color: full ? Colors.deepOrange : null),
          InfoLine(Icons.devices, '${txt(d['label'], 'جهاز بلا اسم')} (${txt(d['platform'])})  •  ${txt(d['device_id'])}'),
          InfoLine(Icons.lan, 'أول IP: ${txt(d['first_ip'])}  •  آخر IP: ${txt(d['last_ip'])}'),
          InfoLine(Icons.schedule, 'الطلب: ${shortTs(d['requested_at'])}  •  آخر ظهور: ${shortTs(d['last_seen_at'])}'),
          if (d['decided_at'] != null)
            InfoLine(
              Icons.gavel,
              'القرار: ${shortTs(d['decided_at'])} بواسطة ${txt(d['decided_by'])}${d['note'] != null ? ' - ${d['note']}' : ''}',
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            if (status != 'approved')
              FilledButton.icon(
                onPressed: () => _approve(context),
                icon: const Icon(Icons.check),
                label: const Text('موافقة'),
                style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700),
              ),
            if (status == 'pending')
              OutlinedButton.icon(
                onPressed: () => _reject(context),
                icon: const Icon(Icons.close),
                label: const Text('رفض'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade700),
              ),
            if (status == 'approved')
              OutlinedButton.icon(
                onPressed: () => _revoke(context),
                icon: const Icon(Icons.block),
                label: const Text('إلغاء الاعتماد'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade700),
              ),
          ]),
        ]),
      ),
    );
  }
}

// ================================================================ sessions

/// Live login sessions; any of them can be ended (the person is sent back to the login screen).
class TechSessionsTab extends StatelessWidget {
  const TechSessionsTab({super.key});

  Future<void> _end(BuildContext context, Map s, Future<void> Function() reload) async {
    final note = await askNote(context, 'إنهاء جلسة ${txt(s['employee_code'])}', label: 'السبب');
    if (note == null || !context.mounted) return;
    await runApi(
      context,
      () => ApiClient.instance.post('/tech/sessions/${s['id']}/end', {'reason': note.isEmpty ? null : note}),
      success: 'أُنهيت الجلسة',
    );
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/tech/sessions',
      builder: (context, data, reload) {
        final rows = ((data as List?) ?? const []).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              SectionTitle('الجلسات الفعّالة (${rows.length})'),
              if (rows.isEmpty) const EmptyNote('لا توجد جلسات فعّالة'),
              for (final s in rows)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${txt(s['employee_code'])} - ${txt(s['full_name'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          InfoLine(Icons.badge, txt(s['role_label'] ?? s['role'])),
                          InfoLine(Icons.devices, '${txt(s['device_label'], 'جهاز غير مسجل')} (${txt(s['platform'])})  •  IP: ${txt(s['ip'])}'),
                          InfoLine(Icons.login, 'بدأت: ${shortTs(s['created_at'])}  •  آخر نشاط: ${shortTs(s['last_seen_at'])}'),
                          InfoLine(Icons.timer_off, 'تنتهي: ${shortTs(s['expires_at'])}'),
                        ]),
                      ),
                      TextButton.icon(
                        onPressed: () => _end(context, s, reload),
                        icon: const Icon(Icons.power_settings_new, color: Colors.red),
                        label: const Text('إنهاء', style: TextStyle(color: Colors.red)),
                      ),
                    ]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
