import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/theme.dart';
import 'cc_widgets.dart';

/// System health: database, WhatsApp gateway, GPS tracking stream, storage, audit-log integrity.
class HealthTab extends StatefulWidget {
  const HealthTab({super.key});

  @override
  State<HealthTab> createState() => _HealthTabState();
}

class _HealthTabState extends State<HealthTab> {
  Map<String, dynamic>? _h;
  Map<String, dynamic>? _audit;
  bool _checkingAudit = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ApiClient.instance.get('/command/health');
      if (mounted) setState(() => _h = Map<String, dynamic>.from(res as Map));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _verifyAudit() async {
    setState(() => _checkingAudit = true);
    try {
      final res = await ApiClient.instance.get('/command/audit/verify');
      if (mounted) setState(() => _audit = Map<String, dynamic>.from(res as Map));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _checkingAudit = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = _h;
    if (h == null) {
      return Center(child: _error != null ? Text(_error!, style: const TextStyle(color: CC.danger)) : const CircularProgressIndicator());
    }
    final wa = h['whatsapp'] as Map;
    final tr = h['tracking'] as Map;
    final st = h['storage'] as Map;
    final failed = (wa['failed_last_hour'] as num? ?? 0) > 0;
    final pings = (tr['pings_last_5_min'] as num? ?? 0);
    final freeGb = (st['free_gb'] as num? ?? 0);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.lg),
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _card('قاعدة البيانات', Icons.storage, CC.ok, 'تعمل', '${h['database']['version']}'),
              _card(
                'بوابة واتساب',
                Icons.chat,
                failed ? CC.danger : (wa['mode'] == 'live' ? CC.ok : CC.warn),
                wa['mode'] == 'live' ? 'إرسال فعلي' : 'وضع التجربة (الطباعة في الخادم)',
                'آخر ساعة: ${wa['sent_last_hour']} رسالة، فشل ${wa['failed_last_hour']}\nآخر نجاح: ${timeAgo(wa['last_success'] as String?)}',
              ),
              _card('تتبع المواقع', Icons.gps_fixed, pings > 0 ? CC.ok : CC.warn, '$pings نقطة / 5 دقائق',
                  'آخر نقطة: ${timeAgo(tr['last_ping'] as String?)}'),
              _card('التخزين', Icons.sd_storage, freeGb < 5 ? CC.danger : CC.ok, '${st['free_gb']} GB متاح', 'من ${st['total_gb']} GB'),
              _card('حماية القاطع', Icons.fence, h['geofence_enforced'] == true ? CC.ok : CC.warn,
                  h['geofence_enforced'] == true ? 'مفعّلة' : 'معطّلة (وضع الاختبار)', 'التحقق بخطوتين: ${(h['two_factor_roles'] as List).join('، ')}'),
              Container(
                width: 300,
                padding: const EdgeInsets.all(Gap.md),
                decoration: BoxDecoration(color: CC.panel, borderRadius: BorderRadius.circular(12), border: Border.all(color: CC.border)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(children: [
                      Icon(Icons.link, color: CC.accent),
                      SizedBox(width: 8),
                      Text('سلامة سجل التدقيق', style: TextStyle(color: CC.text, fontWeight: FontWeight.bold)),
                    ]),
                    const SizedBox(height: 6),
                    Text('${h['audit_log_rows']} سجل مترابط', style: const TextStyle(color: CC.muted)),
                    const SizedBox(height: 8),
                    if (_audit != null)
                      Text(
                        _audit!['valid'] == true ? '✔ السجل سليم ولم يُعدَّل' : '✖ تم اكتشاف تعديل عند السجل ${_audit!['broken_at_id']}',
                        style: TextStyle(color: _audit!['valid'] == true ? CC.ok : CC.danger, fontWeight: FontWeight.bold),
                      ),
                    TextButton(
                      onPressed: _checkingAudit ? null : _verifyAudit,
                      child: Text(_checkingAudit ? 'جاري الفحص...' : 'فحص السجل الآن'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('وقت الخادم: ${h['database']['server_time']}', style: const TextStyle(color: CC.muted, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _card(String title, IconData icon, Color color, String status, String detail) {
    return Container(
      width: 300,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(color: CC.panel, borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(color: CC.text, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 8),
          Text(status, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(detail, style: const TextStyle(color: CC.muted, fontSize: 12)),
        ],
      ),
    );
  }
}
