import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../shared/ui.dart';

const _weekdays = ['الأحد', 'الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت'];

/// Human text for a setting value of any type.
String _display(Map s, dynamic v) {
  final type = '${s['type']}';
  if (v == null) return '-';
  switch (type) {
    case 'bool':
      return v == true ? 'مفعّل' : 'متوقف';
    case 'choice':
      final choices = s['choices'] is Map ? s['choices'] as Map : const {};
      return '${choices['$v'] ?? v}';
    case 'int':
    case 'float':
      final n = asNum(v);
      if (n == null) return '$v';
      return formatNumber(n, decimals: n % 1 == 0 ? 0 : 2);
    case 'list_int':
      if (v is List) {
        return v.map((e) {
          final i = asNum(e)?.toInt();
          return i != null && i >= 0 && i < 7 ? _weekdays[i] : '$e';
        }).join('، ');
      }
      return '$v';
    case 'list_str':
      return v is List ? v.join('، ') : '$v';
    case 'map_int':
      return v is Map ? v.entries.map((e) => '${e.key}: ${e.value}').join(' | ') : '$v';
    default:
      return '$v';
  }
}

/// 'إعداداتي': the business settings the tech panel lets the owner change himself (GET /owner/settings).
class OwnerSettingsTab extends StatefulWidget {
  const OwnerSettingsTab({super.key});

  @override
  State<OwnerSettingsTab> createState() => _OwnerSettingsTabState();
}

class _OwnerSettingsTabState extends State<OwnerSettingsTab> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _edit(Map s) async {
    final result = await showDialog<({dynamic value, String note})>(
      context: context,
      builder: (_) => _SettingDialog(setting: s),
    );
    if (result == null || !mounted) return;
    final r = await runApi(
      context,
      () => ApiClient.instance.post('/owner/settings/${s['key']}', {
        'value': result.value,
        'note': result.note.isEmpty ? null : result.note,
      }),
      success: 'تم حفظ الإعداد',
    );
    if (r != null) _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/owner/settings',
      builder: (context, data, reload) {
        final list = ((data as List?) ?? const []).whereType<Map>().toList();
        final groups = <String, List<Map>>{};
        for (final s in list) {
          groups.putIfAbsent('${s['group_label'] ?? s['group'] ?? ''}', () => []).add(s);
        }
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                color: Colors.blueGrey.withValues(alpha: 0.08),
                child: const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('إعداداتك'),
                  subtitle: Text('هذه إعدادات العمل التي تستطيع تغييرها بنفسك. الإدارة التقنية هي التي تقرر أي الإعدادات تظهر هنا؛ '
                      'إذا احتجت تغيير إعداد غير موجود في القائمة اطلبه منها. كل تغيير يُسجّل باسمك.'),
                ),
              ),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('لم تسمح الإدارة التقنية بأي إعداد لك بعد')),
                ),
              for (final g in groups.entries) ...[
                SectionTitle(g.key),
                Card(
                  child: Column(children: [
                    for (final s in g.value) _tile(s),
                  ]),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(Map s) {
    final overridden = s['overridden'] == true;
    final help = '${s['help'] ?? ''}';
    return ListTile(
      title: Text('${s['label'] ?? s['key']}'),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (help.isNotEmpty) Text(help, style: const TextStyle(fontSize: 12)),
        Text(
          'الافتراضي: ${_display(s, s['default'])}'
          '${overridden && s['updated_at'] != null ? ' | عُدّل ${formatDate(s['updated_at'])}' : ''}',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Text(
            _display(s, s['value']),
            textAlign: TextAlign.end,
            style: TextStyle(fontWeight: FontWeight.bold, color: overridden ? Colors.indigo : null),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
        const Icon(Icons.edit, size: 18),
      ]),
      onTap: () => _edit(s),
    );
  }
}

/// Edit dialog chosen by the setting's type (int/float/bool/choice/time/str/list_int/list_str/map_int).
class _SettingDialog extends StatefulWidget {
  final Map setting;
  const _SettingDialog({required this.setting});

  @override
  State<_SettingDialog> createState() => _SettingDialogState();
}

class _SettingDialogState extends State<_SettingDialog> {
  late final String _type = '${widget.setting['type']}';
  final _text = TextEditingController();
  final _note = TextEditingController();
  bool _bool = false;
  String? _choice;
  final Set<int> _days = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    final v = widget.setting['value'];
    switch (_type) {
      case 'bool':
        _bool = v == true;
      case 'choice':
        _choice = v?.toString();
      case 'list_int':
        if (v is List) _days.addAll(v.map((e) => asNum(e)?.toInt()).whereType<int>());
      case 'list_str':
        _text.text = v is List ? v.join(', ') : '${v ?? ''}';
      case 'map_int':
        _text.text = v is Map ? const JsonEncoder.withIndent('  ').convert(v) : '{}';
      default:
        _text.text = v == null ? '' : '$v';
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final parts = _text.text.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 8,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
    );
    final t = await showTimePicker(context: context, initialTime: initial);
    if (t == null || !mounted) return;
    setState(() => _text.text = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
  }

  /// The value to send, or null (with [_error] set) when invalid.
  Object? _value() {
    final s = widget.setting;
    final t = _text.text.trim();
    final min = asNum(s['min']);
    final max = asNum(s['max']);
    String? rangeError(num n) {
      if (min != null && n < min) return 'أقل قيمة مسموحة ${formatNumber(min, decimals: min % 1 == 0 ? 0 : 2)}';
      if (max != null && n > max) return 'أعلى قيمة مسموحة ${formatNumber(max, decimals: max % 1 == 0 ? 0 : 2)}';
      return null;
    }

    switch (_type) {
      case 'bool':
        return _bool;
      case 'choice':
        if (_choice == null) {
          _error = 'اختر قيمة';
          return null;
        }
        return _choice;
      case 'int':
        final n = int.tryParse(t.replaceAll(',', ''));
        if (n == null) {
          _error = 'أدخل رقماً صحيحاً';
          return null;
        }
        _error = rangeError(n);
        return _error == null ? n : null;
      case 'float':
        final n = double.tryParse(t.replaceAll(',', ''));
        if (n == null) {
          _error = 'أدخل رقماً';
          return null;
        }
        _error = rangeError(n);
        return _error == null ? n : null;
      case 'time':
        if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(t)) {
          _error = 'اكتب الوقت بالشكل 08:30';
          return null;
        }
        return t;
      case 'list_int':
        return (_days.toList()..sort());
      case 'list_str':
        return t.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      case 'map_int':
        try {
          final m = jsonDecode(t.isEmpty ? '{}' : t);
          if (m is! Map || m.values.any((x) => x is! int || x < 0)) throw const FormatException();
          return m;
        } on FormatException {
          _error = 'اكتب القيم بالشكل {"المفتاح": رقم}';
          return null;
        }
      default:
        if (t.isEmpty) {
          _error = 'لا يمكن ترك القيمة فارغة';
          return null;
        }
        return t;
    }
  }

  void _save() {
    setState(() => _error = null);
    final v = _value();
    if (v == null) {
      setState(() {});
      return;
    }
    Navigator.pop<({dynamic value, String note})>(context, (value: v, note: _note.text.trim()));
  }

  Widget _editor() {
    final s = widget.setting;
    switch (_type) {
      case 'bool':
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(_bool ? 'مفعّل' : 'متوقف'),
          value: _bool,
          onChanged: (v) => setState(() => _bool = v),
        );
      case 'choice':
        final choices = s['choices'] is Map ? s['choices'] as Map : const {};
        return Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in choices.entries)
            ChoiceChip(
              label: Text('${e.value}'),
              selected: _choice == '${e.key}',
              onSelected: (_) => setState(() => _choice = '${e.key}'),
            ),
        ]);
      case 'list_int':
        return Wrap(spacing: 6, runSpacing: 6, children: [
          for (var i = 0; i < 7; i++)
            FilterChip(
              label: Text(_weekdays[i]),
              selected: _days.contains(i),
              onSelected: (on) => setState(() => on ? _days.add(i) : _days.remove(i)),
            ),
        ]);
      case 'time':
        return TextField(
          controller: _text,
          keyboardType: TextInputType.datetime,
          decoration: InputDecoration(
            labelText: 'الوقت (ساعة:دقيقة)',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(icon: const Icon(Icons.schedule), onPressed: _pickTime),
          ),
        );
      case 'int':
      case 'float':
        final min = asNum(s['min']);
        final max = asNum(s['max']);
        return TextField(
          controller: _text,
          keyboardType: TextInputType.numberWithOptions(decimal: _type == 'float'),
          decoration: InputDecoration(
            labelText: 'القيمة',
            border: const OutlineInputBorder(),
            helperText: [
              if (min != null) 'الأدنى $min',
              if (max != null) 'الأعلى $max',
            ].join(' | '),
          ),
        );
      case 'map_int':
        return TextField(
          controller: _text,
          maxLines: 6,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(labelText: 'القيم', border: OutlineInputBorder()),
        );
      case 'list_str':
        return TextField(
          controller: _text,
          decoration: const InputDecoration(
            labelText: 'القيم',
            helperText: 'افصل بين القيم بفاصلة ,',
            border: OutlineInputBorder(),
          ),
        );
      default:
        return TextField(
          controller: _text,
          decoration: const InputDecoration(labelText: 'القيمة', border: OutlineInputBorder()),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.setting;
    final help = '${s['help'] ?? ''}';
    return AlertDialog(
      title: Text('${s['label'] ?? s['key']}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (help.isNotEmpty) Text(help, style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text('الحالي: ${_display(s, s['value'])} | الافتراضي: ${_display(s, s['default'])}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            _editor(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'سبب التغيير (اختياري)', border: OutlineInputBorder()),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        ElevatedButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }
}
