import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/format.dart';

/// Shared colours, labels and small widgets for the tech panel (لوحة التقنية).
const kTechColor = Color(0xFF1A237E);

const Map<String, String> techRoleLabels = {
  'collector': 'جابي',
  'supervisor': 'مشرف',
  'finance': 'مالية',
  'command': 'قيادة',
  'hr': 'موارد بشرية',
  'owner': 'المالك',
  'tech': 'التقنية',
  'admin': 'مدير النظام',
};

/// The four switches that can be stopped globally, per sector or per person.
const Map<String, String> switchLabels = {
  'collection': 'الجباية',
  'registration': 'تسجيل العقارات',
  'master_code': 'الرمز الرئيسي',
  'estimates': 'الفواتير التقديرية',
};

/// "2026-10-08T09:15:22.123+03:00" -> "2026-10-08 09:15"
String shortTs(dynamic v) {
  if (v == null) return '-';
  final s = v.toString().trim();
  if (s.isEmpty) return '-';
  final t = s.replaceFirst('T', ' ');
  return t.length > 16 ? t.substring(0, 16) : t;
}

/// A JSON value as display text ('-' for null / empty).
String txt(dynamic v, [String fallback = '-']) {
  if (v == null) return fallback;
  final s = v.toString().trim();
  return s.isEmpty ? fallback : s;
}

int toInt(dynamic v) {
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}') ?? 0;
}

/// 25500 -> "25,500", 2.5 -> "2.5"
String numText(num v) => v == v.roundToDouble() ? formatNumber(v) : v.toString();

/// Arabic-Indic digits (٠-٩) and decimal sign -> ASCII, so numbers typed on an Arabic keyboard parse.
String latinDigits(String s) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = arabic.indexOf(ch);
    b.write(i >= 0 ? '$i' : (ch == '٫' ? '.' : ch));
  }
  return b.toString().trim();
}

/// {'a': 'x', 'b': ''} -> "?a=x" (empty values are left out so the server sees them as not given).
String buildQuery(Map<String, String?> params) {
  final parts = <String>[];
  for (final e in params.entries) {
    final v = e.value;
    if (v != null && v.trim().isNotEmpty) parts.add('${e.key}=${Uri.encodeQueryComponent(v.trim())}');
  }
  return parts.isEmpty ? '' : '?${parts.join('&')}';
}

/// Any JSON value as readable text: strings as they are, everything else as indented JSON.
String prettyJson(dynamic v) {
  if (v == null) return '-';
  if (v is String) return v;
  try {
    return const JsonEncoder.withIndent('  ').convert(v);
  } catch (_) {
    return v.toString();
  }
}

/// Compact JSON for one-line display (e.g. old / new values in the settings history).
String compactJson(dynamic v) {
  if (v == null) return '-';
  if (v is String) return v;
  try {
    return jsonEncode(v);
  } catch (_) {
    return v.toString();
  }
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: error ? Colors.red.shade700 : Colors.green.shade700),
  );
}

/// Icon + text line that wraps on narrow phones.
class InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const InfoLine(this.icon, this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color ?? Colors.grey.shade600),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: color))),
        ],
      ),
    );
  }
}

class EmptyNote extends StatelessWidget {
  final String text;
  const EmptyNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey))),
    );
  }
}

/// One text field of [fieldsDialog].
class FieldSpec {
  final String label;
  final String initial;
  final int maxLines;
  final TextInputType? keyboard;
  final bool obscure;
  final String? hint;
  const FieldSpec(this.label, {this.initial = '', this.maxLines = 1, this.keyboard, this.obscure = false, this.hint});
}

/// A dialog of text fields. Returns the trimmed values, or null when cancelled.
/// [validate] returns an Arabic error message (shown in the dialog) or null when the values are fine.
Future<List<String>?> fieldsDialog(
  BuildContext context,
  String title,
  List<FieldSpec> fields, {
  String? Function(List<String> values)? validate,
  String? intro,
  String submitLabel = 'حفظ',
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (_) => _FieldsDialog(title: title, fields: fields, validate: validate, intro: intro, submitLabel: submitLabel),
  );
}

class _FieldsDialog extends StatefulWidget {
  final String title;
  final List<FieldSpec> fields;
  final String? Function(List<String> values)? validate;
  final String? intro;
  final String submitLabel;
  const _FieldsDialog({required this.title, required this.fields, this.validate, this.intro, required this.submitLabel});

  @override
  State<_FieldsDialog> createState() => _FieldsDialogState();
}

class _FieldsDialogState extends State<_FieldsDialog> {
  late final List<TextEditingController> _c = [for (final f in widget.fields) TextEditingController(text: f.initial)];
  String? _error;

  @override
  void dispose() {
    for (final c in _c) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final values = [for (final c in _c) c.text.trim()];
    final err = widget.validate?.call(values);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.intro != null) ...[
                Text(widget.intro!, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                const SizedBox(height: 8),
              ],
              for (var i = 0; i < widget.fields.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TextField(
                    controller: _c[i],
                    maxLines: widget.fields[i].obscure ? 1 : widget.fields[i].maxLines,
                    keyboardType: widget.fields[i].keyboard,
                    obscureText: widget.fields[i].obscure,
                    decoration: InputDecoration(
                      labelText: widget.fields[i].label,
                      hintText: widget.fields[i].hint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        ElevatedButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}
