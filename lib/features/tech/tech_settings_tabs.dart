import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart' show asNum;
import '../shared/ui.dart';
import 'tech_common.dart';

// ================================================================ settings and formulas

/// A setting value formatted for its registry type.
String settingText(Map item, dynamic v) {
  if (v == null) return '-';
  switch (item['type']) {
    case 'bool':
      return v == true ? 'مفعّل' : 'معطّل';
    case 'choice':
      final c = item['choices'];
      return c is Map ? txt(c[v] ?? v) : txt(v);
    case 'list_int':
    case 'list_str':
      if (v is List) return v.isEmpty ? '(فارغ)' : v.join('، ');
      return txt(v);
    case 'map_int':
      if (v is Map) {
        return v.isEmpty ? '(فارغ)' : v.entries.map((e) => '${techRoleLabels[e.key] ?? e.key}: ${e.value}').join('، ');
      }
      return txt(v);
    case 'int':
    case 'float':
      return v is num ? numText(v) : txt(v);
    default:
      return txt(v, '(فارغ)');
  }
}

/// Every rate, formula and switch, grouped as the server sends them.
class TechSettingsTab extends StatelessWidget {
  const TechSettingsTab({super.key});

  Future<void> _showHistory(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('سجل تغييرات الإعدادات'),
        content: SizedBox(
          width: 560,
          height: 480,
          child: ApiView(
            path: '/tech/settings-history',
            builder: (context, data, reload) {
              final rows = ((data as List?) ?? const []).cast<Map>();
              if (rows.isEmpty) return const EmptyNote('لا توجد تغييرات بعد');
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final r = rows[i];
                  final note = r['note'] == null ? '' : '  •  ${r['note']}';
                  return ListTile(
                    dense: true,
                    title: Text(txt(r['label'] ?? r['key']), style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      'من: ${compactJson(r['old'])}\n'
                      'إلى: ${r['new'] == null ? '(القيمة الافتراضية)' : compactJson(r['new'])}\n'
                      '${shortTs(r['at'])}  •  ${txt(r['by'])}$note',
                    ),
                  );
                },
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/tech/settings',
      builder: (context, data, reload) {
        final all = ((data as List?) ?? const []).cast<Map>();
        final ordered = [
          ...all.where((g) => g['group'] == 'switches'),
          ...all.where((g) => g['group'] == 'money'),
          ...all.where((g) => g['group'] != 'switches' && g['group'] != 'money'),
        ];
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Row(children: [
                const Expanded(
                  child: Text('كل تغيير يُطبّق خلال ثوانٍ ويُسجّل في سجل التغييرات وسجل التدقيق',
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _showHistory(context),
                  icon: const Icon(Icons.history),
                  label: const Text('السجل'),
                ),
              ]),
              const SizedBox(height: 8),
              for (final g in ordered) _group(g, reload),
            ],
          ),
        );
      },
    );
  }

  Widget _group(Map g, Future<void> Function() reload) {
    final items = ((g['items'] as List?) ?? const []).cast<Map>().where((it) => it['type'] != 'json').toList();
    final changed = items.where((it) => it['overridden'] == true).length;
    final open = g['group'] == 'money' || g['group'] == 'switches';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey<String>('tech_settings_${g['group']}'),
        initiallyExpanded: open,
        title: Text(txt(g['label'] ?? g['group']), style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${items.length} إعداد${changed > 0 ? '  •  $changed معدّل' : ''}'),
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _SettingTile(item: items[i], onChanged: reload),
          ],
        ],
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final Map item;
  final Future<void> Function() onChanged;
  const _SettingTile({required this.item, required this.onChanged});

  String get _key => Uri.encodeComponent(txt(item['key'], ''));

  Future<void> _toggle(BuildContext context, bool value) async {
    final note = await askNote(context, '${txt(item['label'])}: ${value ? 'تفعيل' : 'إيقاف'}؟', label: 'سبب التغيير');
    if (note == null || !context.mounted) return;
    await runApi(
      context,
      () => ApiClient.instance.post('/tech/settings/$_key', {'value': value, 'note': note.isEmpty ? null : note}),
      success: 'حُفظ التغيير',
    );
    await onChanged();
  }

  Future<void> _edit(BuildContext context) async {
    final body = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => _SettingEditDialog(item: item));
    if (body == null || !context.mounted) return;
    await runApi(context, () => ApiClient.instance.post('/tech/settings/$_key', body), success: 'حُفظ الإعداد');
    await onChanged();
  }

  Future<void> _reset(BuildContext context) async {
    final ok = await confirm(
      context,
      'إرجاع للافتراضي',
      '«${txt(item['label'])}» يعود إلى ${settingText(item, item['default'])}',
    );
    if (!ok || !context.mounted) return;
    await runApi(context, () => ApiClient.instance.delete('/tech/settings/$_key'), success: 'أُرجع للقيمة الافتراضية');
    await onChanged();
  }

  Future<void> _ownerEditable(BuildContext context, bool allowed) async {
    await runApi(
      context,
      () => ApiClient.instance.post('/tech/settings/$_key/owner-editable', {'allowed': allowed}),
      success: allowed ? 'صار المالك يستطيع تغييره' : 'لم يعد المالك يستطيع تغييره',
    );
    await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isBool = item['type'] == 'bool';
    final overridden = item['overridden'] == true;
    final help = txt(item['help'], '');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(txt(item['label']), style: const TextStyle(fontWeight: FontWeight.w600))),
          if (overridden) StatusChip('معدّل', Colors.orange.shade800),
          if (isBool) Switch(value: item['value'] == true, onChanged: (v) => _toggle(context, v)),
        ]),
        if (help.isNotEmpty) Text(help, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        if (!isBool)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('القيمة: ${settingText(item, item['value'])}',
                style: const TextStyle(fontWeight: FontWeight.bold, color: kTechColor)),
          ),
        if (overridden)
          Text(
            'الافتراضي: ${settingText(item, item['default'])}  •  عُدّل ${shortTs(item['updated_at'])}',
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
          if (!isBool)
            TextButton.icon(onPressed: () => _edit(context), icon: const Icon(Icons.edit, size: 18), label: const Text('تعديل')),
          if (overridden)
            TextButton.icon(
              onPressed: () => _reset(context),
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('إرجاع للافتراضي'),
            ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(value: item['owner_editable'] == true, onChanged: (v) => _ownerEditable(context, v ?? false)),
            const Text('يغيّره المالك', style: TextStyle(fontSize: 13)),
          ]),
          Text(txt(item['key']), textDirection: TextDirection.ltr, style: const TextStyle(color: Colors.grey, fontSize: 11)),
        ]),
      ]),
    );
  }
}

/// Editor for one setting, shaped by its type. Returns {"value": typed value, "note": ...} or null.
class _SettingEditDialog extends StatefulWidget {
  final Map item;
  const _SettingEditDialog({required this.item});

  @override
  State<_SettingEditDialog> createState() => _SettingEditDialogState();
}

class _SettingEditDialogState extends State<_SettingEditDialog> {
  late final String _type = txt(widget.item['type'], 'str');
  late final Map _choices = (widget.item['choices'] as Map?) ?? const {};
  late final num? _min = asNum(widget.item['min']);
  late final num? _max = asNum(widget.item['max']);
  late final TextEditingController _text = TextEditingController(text: _initialText());
  final _note = TextEditingController();
  late String? _choice = _choices.containsKey(widget.item['value'])
      ? '${widget.item['value']}'
      : (_choices.isEmpty ? null : '${_choices.keys.first}');
  late final Map<String, TextEditingController> _map = _initialMap();
  String? _error;
  dynamic _parsed;

  String _initialText() {
    final v = widget.item['value'];
    if (v == null) return '';
    if (v is List) return v.join(', ');
    if (v is num) return v == v.roundToDouble() && _type == 'int' ? '${v.toInt()}' : '$v';
    return '$v';
  }

  Map<String, TextEditingController> _initialMap() {
    if (_type != 'map_int') return {};
    final value = (widget.item['value'] as Map?) ?? const {};
    final defaults = (widget.item['default'] as Map?) ?? const {};
    final keys = <String>{...value.keys.map((k) => '$k'), ...defaults.keys.map((k) => '$k')};
    return {for (final k in keys) k: TextEditingController(text: txt(value[k] ?? defaults[k], ''))};
  }

  @override
  void dispose() {
    _text.dispose();
    _note.dispose();
    for (final c in _map.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _range(num n) {
    final min = _min;
    final max = _max;
    if (min != null && n < min) return 'يجب ألا يقل عن ${numText(min)}';
    if (max != null && n > max) return 'يجب ألا يزيد عن ${numText(max)}';
    return null;
  }

  /// Sets [_parsed] and returns null, or returns an Arabic error.
  String? _parse() {
    final t = latinDigits(_text.text);
    switch (_type) {
      case 'int':
        final asInt = int.tryParse(t.replaceAll(',', ''));
        if (asInt == null) return 'أدخل عدداً صحيحاً';
        _parsed = asInt;
        return _range(asInt);
      case 'float':
        final asDouble = double.tryParse(t.replaceAll(',', ''));
        if (asDouble == null) return 'أدخل رقماً';
        _parsed = asDouble;
        return _range(asDouble);
      case 'time':
        final m = RegExp(r'^([01]?\d|2[0-3]):([0-5]\d)$').firstMatch(t);
        if (m == null) return 'أدخل الوقت بصيغة HH:MM مثل 08:00';
        _parsed = '${m.group(1)!.padLeft(2, '0')}:${m.group(2)}';
        return null;
      case 'choice':
        if (_choice == null) return 'اختر قيمة';
        _parsed = _choice;
        return null;
      case 'list_int':
        final parts = t.split(RegExp(r'[,،\s]+')).where((p) => p.isNotEmpty).toList();
        final nums = <int>[];
        for (final p in parts) {
          final day = int.tryParse(p);
          if (day == null) return '«$p» ليس عدداً صحيحاً';
          nums.add(day);
        }
        _parsed = nums;
        return null;
      case 'list_str':
        _parsed = _text.text.split(RegExp(r'[,،]')).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
        return null;
      case 'map_int':
        final out = <String, int>{};
        for (final e in _map.entries) {
          final count = int.tryParse(latinDigits(e.value.text));
          if (count == null || count < 0) return 'قيمة «${techRoleLabels[e.key] ?? e.key}» يجب أن تكون عدداً صحيحاً موجباً';
          out[e.key] = count;
        }
        _parsed = out;
        return null;
      default:
        final s = _text.text.trim();
        if (s.isEmpty) return 'القيمة لا يمكن أن تكون فارغة';
        _parsed = s;
        return null;
    }
  }

  void _submit() {
    final err = _parse();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final note = _note.text.trim();
    Navigator.pop(context, <String, dynamic>{'value': _parsed, 'note': note.isEmpty ? null : note});
  }

  Widget _editor() {
    switch (_type) {
      case 'choice':
        return InputDecorator(
          decoration: const InputDecoration(labelText: 'القيمة', border: OutlineInputBorder(), isDense: true),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _choice,
              isDense: true,
              isExpanded: true,
              items: [for (final e in _choices.entries) DropdownMenuItem(value: '${e.key}', child: Text(txt(e.value)))],
              onChanged: (v) => setState(() => _choice = v),
            ),
          ),
        );
      case 'map_int':
        return Column(mainAxisSize: MainAxisSize.min, children: [
          for (final e in _map.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: TextField(
                controller: e.value,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: techRoleLabels[e.key] ?? e.key,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
        ]);
      default:
        final numeric = _type == 'int' || _type == 'float';
        final min = _min;
        final max = _max;
        final limits = [
          if (min != null) 'الأدنى ${numText(min)}',
          if (max != null) 'الأعلى ${numText(max)}',
        ].join('  •  ');
        final helper = switch (_type) {
          'time' => 'بصيغة HH:MM (24 ساعة)',
          'list_int' => 'أرقام مفصولة بفاصلة، مثل 4, 5',
          'list_str' => 'قيم مفصولة بفاصلة (اتركه فارغاً لعدم التقييد)',
          _ => limits.isEmpty ? null : limits,
        };
        return TextField(
          controller: _text,
          keyboardType: numeric ? TextInputType.numberWithOptions(decimal: _type == 'float') : null,
          decoration: InputDecoration(labelText: 'القيمة', helperText: helper, border: const OutlineInputBorder(), isDense: true),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return AlertDialog(
      title: Text(txt(item['label'])),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (txt(item['help'], '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(txt(item['help']), style: const TextStyle(color: Colors.grey, fontSize: 13)),
              ),
            Text('الحالية: ${settingText(item, item['value'])}  •  الافتراضية: ${settingText(item, item['default'])}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            _editor(),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'سبب التغيير (اختياري)', border: OutlineInputBorder(), isDense: true),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        ElevatedButton(onPressed: _submit, child: const Text('حفظ')),
      ],
    );
  }
}

// ================================================================ permission matrix

/// Which role sees which tab. Hiding a tab blocks it in the app and on the server.
class TechPermissionsTab extends StatelessWidget {
  const TechPermissionsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/tech/permissions',
      builder: (context, data, reload) {
        final roles = ((data as List?) ?? const []).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                color: kTechColor.withValues(alpha: 0.06),
                child: const ListTile(
                  leading: Icon(Icons.info_outline, color: kTechColor),
                  title: Text('إخفاء قسم يمنع الوصول إليه في الواجهة والخادم'),
                  subtitle: Text('قد يحتاج الموظف لإعادة الدخول حتى يختفي القسم أو يظهر في واجهته'),
                ),
              ),
              for (final r in roles) _roleCard(context, r, reload),
            ],
          ),
        );
      },
    );
  }

  Widget _roleCard(BuildContext context, Map r, Future<void> Function() reload) {
    final features = ((r['features'] as List?) ?? const []).cast<Map>();
    final on = features.where((f) => f['allowed'] == true).length;
    return Card(
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              Expanded(
                child: Text(txt(r['role_label'] ?? r['role']), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              StatusChip('$on من ${features.length} مفعّل', on == features.length ? Colors.green.shade700 : Colors.orange.shade800),
            ]),
          ),
          for (final f in features)
            SwitchListTile(
              dense: true,
              title: Text(txt(f['label'])),
              subtitle: Text(txt(f['key']), textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 11)),
              value: f['allowed'] == true,
              onChanged: (v) async {
                await runApi(
                  context,
                  () => ApiClient.instance.post('/tech/permissions', {'role': r['role'], 'feature': f['key'], 'allowed': v}),
                  success: v ? 'أُظهر القسم' : 'أُخفي القسم',
                );
                await reload();
              },
            ),
        ]),
      ),
    );
  }
}
