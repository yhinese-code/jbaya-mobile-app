import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../shared/ui.dart';
import 'tech_common.dart';

/// Parses "lat,lng" lines (one point per line) into [[lat, lng], ...].
({List<List<double>> points, String? error}) parsePolygon(String text) {
  final points = <List<double>>[];
  for (final raw in text.split('\n')) {
    final line = latinDigits(raw);
    if (line.isEmpty) continue;
    final parts = line.split(RegExp(r'[,،\s]+')).where((p) => p.isNotEmpty).toList();
    if (parts.length != 2) return (points: points, error: 'السطر «$line» يجب أن يكون بصيغة lat,lng');
    final lat = double.tryParse(parts[0]);
    final lng = double.tryParse(parts[1]);
    if (lat == null || lng == null || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      return (points: points, error: 'إحداثيات غير صالحة في السطر «$line»');
    }
    points.add([lat, lng]);
  }
  if (points.length < 3) return (points: points, error: 'الحدود تحتاج 3 نقاط على الأقل');
  return (points: points, error: null);
}

String polygonText(dynamic polygon) {
  if (polygon is! List) return '';
  return polygon.whereType<List>().map((p) => p.join(',')).join('\n');
}

/// Sectors (boundaries, active flag, per-sector switches) and the tariff table.
class TechSectorsTab extends StatefulWidget {
  const TechSectorsTab({super.key});

  @override
  State<TechSectorsTab> createState() => _TechSectorsTabState();
}

class _TechSectorsTabState extends State<TechSectorsTab> {
  final _sectorsKey = GlobalKey<ApiViewState>();
  final _tariffsKey = GlobalKey<ApiViewState>();

  Future<void> _reloadAll() async {
    final a = _sectorsKey.currentState;
    final b = _tariffsKey.currentState;
    await Future.wait([if (a != null) a.reload(), if (b != null) b.reload()]);
  }

  Future<void> _newSector() async {
    final v = await fieldsDialog(
      context,
      'قاطع جديد',
      const [
        FieldSpec('رمز القاطع (مثل S-07)'),
        FieldSpec('الاسم'),
        FieldSpec('المحلة (اختياري)'),
        FieldSpec('الحدود: نقطة في كل سطر', maxLines: 6, hint: '33.3128,44.3615\n33.3150,44.3702\n33.3089,44.3720'),
      ],
      intro: 'اكتب نقاط حدود القاطع بالترتيب حول المنطقة، كل نقطة في سطر: خط العرض ثم خط الطول.',
      submitLabel: 'إنشاء',
      validate: (vals) {
        if (vals[0].length < 2) return 'رمز القاطع حرفان على الأقل';
        if (vals[1].length < 2) return 'اسم القاطع حرفان على الأقل';
        return parsePolygon(vals[3]).error;
      },
    );
    if (v == null || !mounted) return;
    await runApi(
      context,
      () => ApiClient.instance.post('/tech/sectors', {
        'code': v[0],
        'name': v[1],
        'mahalla': v[2].isEmpty ? null : v[2],
        'polygon': parsePolygon(v[3]).points,
      }),
      success: 'أُنشئ القاطع',
    );
    await _sectorsKey.currentState?.reload();
  }

  Future<void> _editTariff(BuildContext context, Map t, Future<void> Function() reload) async {
    final v = await fieldsDialog(
      context,
      'تعرفة ${txt(t['label'])}',
      [
        FieldSpec('سعر الوحدة (د.ع لكل م³)', initial: txt(t['unit_rate'], ''), keyboard: const TextInputType.numberWithOptions(decimal: true)),
        FieldSpec('التقدير الشهري (د.ع)', initial: txt(t['monthly_estimate'], ''), keyboard: const TextInputType.numberWithOptions(decimal: true)),
      ],
      intro: 'تُطبّق على الفواتير الجديدة فقط.',
      validate: (vals) {
        for (final x in vals) {
          final n = double.tryParse(latinDigits(x).replaceAll(',', ''));
          if (n == null || n < 0) return 'أدخل أرقاماً موجبة';
        }
        return null;
      },
    );
    if (v == null || !context.mounted) return;
    final rate = double.parse(latinDigits(v[0]).replaceAll(',', ''));
    final estimate = double.parse(latinDigits(v[1]).replaceAll(',', ''));
    await runApi(
      context,
      () => ApiClient.instance.post('/tech/tariffs/${Uri.encodeComponent(txt(t['property_class'], ''))}',
          {'unit_rate': rate, 'monthly_estimate': estimate}),
      success: 'حُفظت التعرفة',
    );
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _reloadAll,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SectionTitle('القواطع', actions: [
            FilledButton.icon(
              onPressed: _newSector,
              icon: const Icon(Icons.add_location_alt),
              label: const Text('قاطع جديد'),
              style: FilledButton.styleFrom(backgroundColor: kTechColor),
            ),
          ]),
          ApiView(
            key: _sectorsKey,
            path: '/tech/sectors',
            builder: (context, data, reload) {
              final rows = ((data as List?) ?? const []).cast<Map>();
              if (rows.isEmpty) return const EmptyNote('لا توجد قواطع');
              return Column(children: [for (final s in rows) _SectorCard(sector: s, onChanged: reload)]);
            },
          ),
          const SectionTitle('التعرفة'),
          ApiView(
            key: _tariffsKey,
            path: '/tech/tariffs',
            builder: (context, data, reload) {
              final rows = ((data as List?) ?? const []).cast<Map>();
              if (rows.isEmpty) return const EmptyNote('لا توجد تعرفة');
              return Card(
                child: Column(children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      isThreeLine: true,
                      title: Text('${txt(rows[i]['label'])} (${txt(rows[i]['property_class'])})',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        'سعر الوحدة: ${numText(asNum(rows[i]['unit_rate']) ?? 0)} د.ع لكل م³\n'
                        'التقدير الشهري: ${formatIqd(asNum(rows[i]['monthly_estimate']))}  •  آخر تعديل: ${shortTs(rows[i]['updated_at'])}',
                      ),
                      trailing: IconButton(
                        tooltip: 'تعديل',
                        icon: const Icon(Icons.edit),
                        onPressed: () => _editTariff(context, rows[i], reload),
                      ),
                    ),
                  ],
                ]),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SectorCard extends StatelessWidget {
  final Map sector;
  final Future<void> Function() onChanged;
  const _SectorCard({required this.sector, required this.onChanged});

  String get _name => '${txt(sector['code'])} - ${txt(sector['name'])}';

  Future<void> _patch(BuildContext context, Map<String, dynamic> body, String success) async {
    await runApi(context, () => ApiClient.instance.patch('/tech/sectors/${sector['id']}', body), success: success);
    await onChanged();
  }

  Future<void> _toggleActive(BuildContext context, bool active) async {
    if (!active) {
      final ok = await confirm(context, 'إيقاف القاطع', 'إيقاف «$_name»؟');
      if (!ok || !context.mounted) return;
    }
    await _patch(context, {'active': active}, active ? 'فُعّل القاطع' : 'أُوقف القاطع');
  }

  Future<void> _toggleSwitch(BuildContext context, String key, bool follow) async {
    final label = switchLabels[key] ?? key;
    // true = follow the global switch (the server removes the stop); false = stopped in this sector only.
    await _patch(context, {'switches': {key: follow}}, follow ? '$label تتبع المفتاح العام هنا' : 'أُوقفت $label في هذا القاطع');
  }

  Future<void> _editInfo(BuildContext context) async {
    final v = await fieldsDialog(
      context,
      'تعديل $_name',
      [FieldSpec('الاسم', initial: txt(sector['name'], '')), FieldSpec('المحلة', initial: txt(sector['mahalla'], ''))],
      validate: (vals) => vals[0].length < 2 ? 'الاسم حرفان على الأقل' : null,
    );
    if (v == null || !context.mounted) return;
    final body = <String, dynamic>{
      if (v[0] != txt(sector['name'], '')) 'name': v[0],
      if (v[1] != txt(sector['mahalla'], '')) 'mahalla': v[1],
    };
    if (body.isEmpty) {
      showSnack(context, 'لا توجد تعديلات');
      return;
    }
    await _patch(context, body, 'حُفظ القاطع');
  }

  Future<void> _editPolygon(BuildContext context) async {
    final v = await fieldsDialog(
      context,
      'حدود $_name',
      [FieldSpec('نقطة في كل سطر: lat,lng', initial: polygonText(sector['polygon']), maxLines: 10)],
      intro: 'النقاط بالترتيب حول القاطع. تُستخدم لمنع التسجيل خارج القاطع.',
      validate: (vals) => parsePolygon(vals[0]).error,
    );
    if (v == null || !context.mounted) return;
    await _patch(context, {'polygon': parsePolygon(v[0]).points}, 'حُفظت الحدود');
  }

  @override
  Widget build(BuildContext context) {
    final s = sector;
    final active = s['active'] != false;
    final sw = (s['switches'] as Map?) ?? const {};
    final points = s['polygon'] is List ? (s['polygon'] as List).length : 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_name, style: const TextStyle(fontWeight: FontWeight.bold))),
            Text(active ? 'فعّال' : 'موقوف', style: TextStyle(color: active ? Colors.green.shade700 : Colors.red.shade700)),
            Switch(value: active, onChanged: (v) => _toggleActive(context, v)),
          ]),
          InfoLine(Icons.location_city, 'المحلة: ${txt(s['mahalla'])}  •  منازل فعّالة: ${toInt(s['houses'])}'),
          InfoLine(Icons.groups, 'الموظفون: ${toInt(s['staff'])}${s['staff_codes'] != null ? ' (${s['staff_codes']})' : ''}'),
          const SizedBox(height: 8),
          const Text('المفاتيح في هذا القاطع:', style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final e in switchLabels.entries)
              FilterChip(
                label: Text('${e.value}: ${sw[e.key] == false ? 'متوقفة هنا' : 'تتبع العام'}'),
                selected: sw[e.key] != false,
                selectedColor: Colors.green.withValues(alpha: 0.15),
                backgroundColor: Colors.red.withValues(alpha: 0.08),
                onSelected: (v) => _toggleSwitch(context, e.key, v),
              ),
          ]),
          Wrap(spacing: 4, children: [
            TextButton.icon(onPressed: () => _editInfo(context), icon: const Icon(Icons.edit, size: 18), label: const Text('الاسم والمحلة')),
            TextButton.icon(
              onPressed: () => _editPolygon(context),
              icon: const Icon(Icons.edit_location_alt, size: 18),
              label: Text('الحدود ($points نقطة)'),
            ),
          ]),
        ]),
      ),
    );
  }
}
