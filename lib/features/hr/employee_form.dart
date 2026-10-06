import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../shared/ui.dart';

/// Create (existing == null) or edit an employee's HR file.
class EmployeeFormScreen extends StatefulWidget {
  final Map<String, dynamic>? existing; // profile map from GET /hr/employees/{code}
  const EmployeeFormScreen({super.key, this.existing});

  @override
  State<EmployeeFormScreen> createState() => _EmployeeFormScreenState();
}

class _EmployeeFormScreenState extends State<EmployeeFormScreen> {
  final Map<String, TextEditingController> _c = {};
  String _role = 'collector';
  DateTime? _hire;
  DateTime? _contractEnd;
  DateTime? _birth;
  List<Map<String, dynamic>> _sectors = [];
  List<Map<String, dynamic>> _supervisors = [];
  String? _sector;
  String? _supervisor;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.existing == null;

  static const _text = [
    'employee_code', 'full_name', 'password', 'phone', 'job_title', 'department', 'national_id_no', 'home_address',
    'emergency_contact', 'base_salary', 'allowance_transport', 'allowance_phone', 'allowance_risk', 'daily_target_iqd',
    'payment_method', 'hr_notes',
  ];
  static const _money = ['base_salary', 'allowance_transport', 'allowance_phone', 'allowance_risk', 'daily_target_iqd'];

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    for (final k in _text) {
      final v = e[k];
      _c[k] = TextEditingController(text: v == null ? '' : (v is num ? v.round().toString() : '$v'));
    }
    if (e['phone'] != null && '${e['phone']}'.startsWith('964')) _c['phone']!.text = '0${'${e['phone']}'.substring(3)}';
    _role = (e['role'] as String?) ?? 'collector';
    _hire = DateTime.tryParse('${e['hire_date'] ?? ''}');
    _contractEnd = DateTime.tryParse('${e['contract_end'] ?? ''}');
    _birth = DateTime.tryParse('${e['birth_date'] ?? ''}');
    _sector = e['sector_code'] as String?;
    _supervisor = e['supervisor_code'] as String?;
    _loadRefs();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadRefs() async {
    try {
      final res = await Future.wait([ApiClient.instance.get('/sectors'), ApiClient.instance.get('/hr/employees?role=supervisor&active=true')]);
      if (!mounted) return;
      setState(() {
        _sectors = (res[0] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _supervisors = (res[1] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      });
    } on ApiException catch (_) {}
  }

  Future<void> _save() async {
    final body = <String, dynamic>{};
    for (final k in _text) {
      final t = _c[k]!.text.trim();
      if (!_isNew && (k == 'employee_code')) continue;
      if (k == 'password' && t.isEmpty) continue;
      if (_money.contains(k)) {
        if (t.isEmpty) {
          if (_isNew && k != 'daily_target_iqd') body[k] = 0;
          continue;
        }
        final v = double.tryParse(t.replaceAll(',', ''));
        if (v == null) {
          setState(() => _error = 'قيمة غير صحيحة في حقل الراتب/البدلات');
          return;
        }
        body[k] = v;
      } else if (t.isNotEmpty) {
        body[k] = t;
      }
    }
    if (_isNew) body['role'] = _role;
    if (_sector != null) body['sector_code'] = _sector;
    if (_supervisor != null) body['supervisor_code'] = _supervisor;
    if (_hire != null) body['hire_date'] = apiDate(_hire!);
    if (_contractEnd != null) body['contract_end'] = apiDate(_contractEnd!);
    if (_birth != null) body['birth_date'] = apiDate(_birth!);
    if (_isNew && (body['employee_code'] == null || body['full_name'] == null || body['password'] == null)) {
      setState(() => _error = 'رقم الموظف والاسم وكلمة المرور (8 أحرف على الأقل) مطلوبة');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isNew) {
        await ApiClient.instance.post('/hr/employees', body);
      } else {
        await ApiClient.instance.patch('/hr/employees/${widget.existing!['employee_code']}', body);
      }
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String key, String label, {bool number = false, bool obscure = false, int lines = 1}) {
    return SizedBox(
      width: 300,
      child: TextField(
        controller: _c[key],
        obscureText: obscure,
        maxLines: lines,
        keyboardType: number ? TextInputType.number : null,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }

  Widget _dateField(String label, DateTime? value, ValueChanged<DateTime?> onChanged) {
    return SizedBox(
      width: 300,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.event),
        label: Text('$label: ${value == null ? '-' : apiDate(value)}'),
        onPressed: () async {
          final d = await showDatePicker(context: context, initialDate: value ?? DateTime.now(),
              firstDate: DateTime(1950), lastDate: DateTime(2100));
          if (d != null) setState(() => onChanged(d));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'موظف جديد' : 'تعديل ملف ${widget.existing!['employee_code']}'),
        backgroundColor: const Color(0xFF6A1B9A),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle('البيانات الأساسية'),
            Wrap(spacing: 12, runSpacing: 12, children: [
              if (_isNew) _field('employee_code', 'رقم الموظف (مثال JB-0500)'),
              _field('full_name', 'الاسم الكامل'),
              if (_isNew)
                SizedBox(
                  width: 300,
                  child: DropdownButtonFormField<String>(
                    initialValue: _role,
                    decoration: const InputDecoration(labelText: 'الدور', border: OutlineInputBorder(), isDense: true),
                    items: const ['collector', 'supervisor', 'finance', 'hr']
                        .map((r) => DropdownMenuItem(value: r, child: Text(roleLabels[r] ?? r)))
                        .toList(),
                    onChanged: (v) => setState(() => _role = v ?? 'collector'),
                  ),
                ),
              _field('password', _isNew ? 'كلمة المرور' : 'كلمة مرور جديدة (اتركها فارغة)', obscure: true),
              _field('phone', 'رقم الهاتف (07...)'),
              _field('job_title', 'المسمى الوظيفي'),
              _field('department', 'القسم'),
              _field('national_id_no', 'رقم البطاقة الوطنية'),
              _dateField('تاريخ الميلاد', _birth, (d) => _birth = d),
              _field('home_address', 'عنوان السكن'),
              _field('emergency_contact', 'جهة اتصال للطوارئ'),
            ]),
            const SectionTitle('العمل والعقد'),
            Wrap(spacing: 12, runSpacing: 12, children: [
              SizedBox(
                width: 300,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('sector-${_sectors.length}'),
                  initialValue: _sectors.any((s) => s['code'] == _sector) ? _sector : null,
                  decoration: const InputDecoration(labelText: 'القاطع', border: OutlineInputBorder(), isDense: true),
                  items: _sectors.map((s) => DropdownMenuItem(value: s['code'] as String, child: Text('${s['code']} - ${s['name']}'))).toList(),
                  onChanged: (v) => setState(() => _sector = v),
                ),
              ),
              SizedBox(
                width: 300,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('sup-${_supervisors.length}'),
                  initialValue: _supervisors.any((s) => s['employee_code'] == _supervisor) ? _supervisor : null,
                  decoration: const InputDecoration(labelText: 'المشرف المباشر', border: OutlineInputBorder(), isDense: true),
                  items: _supervisors
                      .map((s) => DropdownMenuItem(value: s['employee_code'] as String, child: Text('${s['employee_code']} - ${s['full_name']}')))
                      .toList(),
                  onChanged: (v) => setState(() => _supervisor = v),
                ),
              ),
              _dateField('تاريخ المباشرة', _hire, (d) => _hire = d),
              _dateField('نهاية العقد', _contractEnd, (d) => _contractEnd = d),
            ]),
            const SectionTitle('الراتب والبدلات (د.ع شهرياً)'),
            Wrap(spacing: 12, runSpacing: 12, children: [
              _field('base_salary', 'الراتب الأساسي', number: true),
              _field('allowance_transport', 'بدل النقل', number: true),
              _field('allowance_phone', 'بدل الهاتف', number: true),
              _field('allowance_risk', 'بدل الخطورة (حمل النقد)', number: true),
              _field('daily_target_iqd', 'الهدف اليومي للتحصيل (للجباة)', number: true),
              _field('payment_method', 'طريقة استلام الراتب'),
            ]),
            if (!_isNew) ...[
              const SectionTitle('ملاحظات الموارد البشرية'),
              SizedBox(width: 612, child: _field('hr_notes', 'ملاحظات داخلية', lines: 3)),
            ],
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save),
              label: Text(_isNew ? 'إنشاء الموظف' : 'حفظ التعديلات'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6A1B9A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
