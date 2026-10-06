import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../shared/photo_dialog.dart';
import 'cc_widgets.dart';

/// Pop-up with everything about one property (opened by clicking its dot on the map or searching for it).
Future<void> showPropertyDialog(BuildContext context, String propertyCode) {
  return showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: CC.panel,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 760),
        child: FutureBuilder<dynamic>(
          future: ApiClient.instance.get('/command/properties/$propertyCode'),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
            }
            if (snap.hasError) {
              return Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}', style: const TextStyle(color: CC.danger)));
            }
            return _PropertyDetail(data: Map<String, dynamic>.from(snap.data as Map));
          },
        ),
      ),
    ),
  );
}

class _PropertyDetail extends StatelessWidget {
  final Map<String, dynamic> data;
  const _PropertyDetail({required this.data});

  static const _status = {
    'paid': 'مدفوعة',
    'awaiting_otp': 'بانتظار رمز المواطن',
    'pending_approval': 'بانتظار موافقة المشرف',
    'blocked_review': 'قيد مراجعة المشرف',
    'cancelled': 'ملغاة',
  };

  @override
  Widget build(BuildContext context) {
    final d = data;
    final color = CC.propertyColor(d['status_color'] as String?);
    final bills = (d['bills'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final flags = (d['flags'] as List? ?? []).join('، ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: color, width: 3))),
          child: Row(
            children: [
              Icon(Icons.home, color: color, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${d['property_code']} - ${d['citizen_name']}',
                        style: const TextStyle(color: CC.text, fontSize: 18, fontWeight: FontWeight.bold)),
                    Text('${d['address']} | ${d['sector_name']}', style: const TextStyle(color: CC.muted)),
                  ],
                ),
              ),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(20),
            children: [
              Wrap(
                spacing: 24,
                runSpacing: 12,
                children: [
                  _field('الحالة', d['days_since_paid'] == null ? 'لم تُجبَ بعد' : 'آخر دفع قبل ${d['days_since_paid']} يوم', color),
                  _field('فئة العقار', propertyClassLabels[d['property_class']] ?? '${d['property_class']}'),
                  _field('العداد', '${meterStatusLabels[d['meter_status']] ?? d['meter_status']}${d['meter_serial'] != null ? ' (${d['meter_serial']})' : ''}'),
                  _field('آخر قراءة', d['last_reading'] == null ? '-' : '${formatNumber(asNum(d['last_reading']), decimals: 1)} م³'),
                  _field('واتساب المواطن', '${d['phone_masked']}${d['phone_verified'] == true ? ' ✔' : ''}'),
                  _field('مجموع المدفوع', '${formatIqd(asNum(d['total_paid']))} (${d['receipts_count']} وصل)'),
                  _field('سُجِّل بواسطة', '${d['registered_by']}'),
                  _field('تاريخ التسجيل', _date(d['registered_at'] as String?)),
                  _field('الموقع', '${(asNum(d['lat']) ?? 0).toStringAsFixed(5)}, ${(asNum(d['lng']) ?? 0).toStringAsFixed(5)}'
                      '${d['gps_accuracy_m'] != null ? ' (±${(asNum(d['gps_accuracy_m']) ?? 0).round()} م)' : ''}'),
                ],
              ),
              if (flags.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('مؤشرات: $flags', style: const TextStyle(color: CC.warn)),
              ],
              const SizedBox(height: 20),
              const Text('الفواتير', style: TextStyle(color: CC.text, fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              if (bills.isEmpty) const Text('لا توجد فواتير', style: TextStyle(color: CC.muted)),
              ...bills.map((b) {
                final paid = b['status'] == 'paid';
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: CC.panelHigh,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: paid ? CC.ok.withValues(alpha: 0.4) : CC.border),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${formatIqd(asNum(b['total_amount']))} | ${_status[b['status']] ?? b['status']}'
                                '${b['receipt_no'] != null ? ' | ${b['receipt_no']}' : ''}',
                                style: TextStyle(color: paid ? CC.ok : CC.text, fontWeight: FontWeight.bold)),
                            Text(
                              '${_date(b['created_at'] as String?)} | ${b['collector_code']} | '
                              '${b['billing_method'] == 'reading' ? 'قراءة' : 'تقدير'} ${b['period_days']} يوم'
                              '${b['consumption'] != null ? ' | استهلاك ${formatNumber(asNum(b['consumption']), decimals: 1)} م³' : ''}'
                              '${b['verification_method'] == 'master_code' ? ' | رمز رئيسي' : ''}',
                              style: const TextStyle(color: CC.muted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      if (b['has_photo'] == true)
                        IconButton(
                          tooltip: 'صورة العداد',
                          onPressed: () => showEvidencePhoto(context, '/bills/${b['id']}/photo', title: 'صورة العداد'),
                          icon: const Icon(Icons.photo, color: CC.accent),
                        ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(String label, String value, [Color? color]) {
    return SizedBox(
      width: 210,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: CC.muted, fontSize: 12)),
          Text(value, style: TextStyle(color: color ?? CC.text, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  static String _date(String? iso) {
    final t = DateTime.tryParse(iso ?? '')?.toLocal();
    if (t == null) return '-';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}
