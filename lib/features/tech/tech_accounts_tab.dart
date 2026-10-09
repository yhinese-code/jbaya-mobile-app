import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/theme.dart';
import '../shared/ui.dart';
import 'tech_common.dart';

/// Every account in the system: roles, sector, supervisor, suspension, passwords, sessions and per-person switches.
class TechAccountsTab extends StatefulWidget {
  const TechAccountsTab({super.key});

  @override
  State<TechAccountsTab> createState() => _TechAccountsTabState();
}

class _TechAccountsTabState extends State<TechAccountsTab> {
  final _listKey = GlobalKey<ApiViewState>();
  final _search = TextEditingController();
  String? _role;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _reload() async => _listKey.currentState?.reload();

  Future<void> _create() async {
    final body = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => const _EmployeeFormDialog());
    if (body == null || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/tech/employees', body), success: 'أُنشئ الحساب');
    await _reload();
  }

  bool _matches(Map e) {
    if (_role != null && e['role'] != _role) return false;
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [e['employee_code'], e['full_name'], e['phone'], e['sector_code'], e['sector_name'], e['supervisor_code']]
        .any((v) => v != null && v.toString().toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'tech_new_employee',
        backgroundColor: kTechColor,
        foregroundColor: Colors.white,
        onPressed: _create,
        icon: const Icon(Icons.person_add),
        label: const Text('موظف جديد'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'بحث بالرقم أو الاسم أو الهاتف أو القاطع',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                child: ChoiceChip(label: const Text('الكل'), selected: _role == null, onSelected: (_) => setState(() => _role = null)),
              ),
              for (final r in techRoleLabels.entries)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ChoiceChip(
                    label: Text(r.value),
                    selected: _role == r.key,
                    onSelected: (sel) => setState(() => _role = sel ? r.key : null),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ApiView(
            key: _listKey,
            path: '/tech/employees',
            builder: (context, data, reload) {
              final all = ((data as List?) ?? const []).cast<Map>();
              final rows = all.where(_matches).toList();
              return RefreshIndicator(
                onRefresh: reload,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
                  children: [
                    Text('${rows.length} من ${all.length} حساب', style: const TextStyle(color: AppColors.muted)),
                    if (rows.isEmpty) const EmptyNote('لا توجد حسابات مطابقة'),
                    for (final e in rows) _EmployeeCard(employee: e, onChanged: reload),
                  ],
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _EmployeeCard extends StatelessWidget {
  final Map employee;
  final Future<void> Function() onChanged;
  const _EmployeeCard({required this.employee, required this.onChanged});

  String get _code => Uri.encodeComponent(txt(employee['employee_code'], ''));

  Future<void> _onAction(BuildContext context, String action) async {
    final e = employee;
    final name = '${txt(e['employee_code'])} - ${txt(e['full_name'])}';
    switch (action) {
      case 'edit':
        final body = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => _EmployeeFormDialog(initial: e));
        if (body == null || !context.mounted) return;
        if (body.isEmpty) {
          showSnack(context, 'لا توجد تعديلات');
          return;
        }
        await runApi(context, () => ApiClient.instance.patch('/tech/employees/$_code', body), success: 'حُفظت التعديلات');
      case 'perms':
        final perms = await showDialog<Map<String, bool?>>(
          context: context,
          builder: (_) => _PermissionsDialog(name: name, current: (e['permissions'] as Map?) ?? const {}),
        );
        if (perms == null || !context.mounted) return;
        await runApi(
          context,
          () => ApiClient.instance.patch('/tech/employees/$_code', {'permissions': perms}),
          success: 'حُفظت الصلاحيات الشخصية',
        );
      case 'suspend':
        final suspendReason = await askNote(context, 'إيقاف حساب $name', required: true, label: 'سبب الإيقاف');
        if (suspendReason == null || !context.mounted) return;
        await runApi(context, () => ApiClient.instance.post('/tech/employees/$_code/suspend', {'reason': suspendReason}),
            success: 'أُوقف الحساب وأُنهيت جلساته');
      case 'reactivate':
        final ok = await confirm(context, 'إعادة تفعيل', 'إعادة تفعيل حساب $name؟');
        if (!ok || !context.mounted) return;
        await runApi(context, () => ApiClient.instance.post('/tech/employees/$_code/reactivate'), success: 'أُعيد تفعيل الحساب');
      case 'password':
        final pw = await fieldsDialog(
          context,
          'كلمة مرور جديدة لـ $name',
          const [FieldSpec('كلمة المرور الجديدة', obscure: true), FieldSpec('تأكيد كلمة المرور', obscure: true)],
          intro: 'تُنهى كل جلسات الموظف بعد التغيير.',
          validate: (vals) {
            if (vals[0].length < 8) return 'كلمة المرور 8 أحرف على الأقل';
            if (vals[0] != vals[1]) return 'كلمتا المرور غير متطابقتين';
            return null;
          },
        );
        if (pw == null || !context.mounted) return;
        await runApi(context, () => ApiClient.instance.post('/tech/employees/$_code/password', {'new_password': pw[0]}),
            success: 'تغيّرت كلمة المرور');
      case 'logout':
        final logoutReason = await askNote(context, 'إنهاء كل جلسات $name', label: 'السبب');
        if (logoutReason == null || !context.mounted) return;
        await runApi(
          context,
          () => ApiClient.instance.post('/tech/employees/$_code/logout', {'reason': logoutReason.isEmpty ? null : logoutReason}),
          success: 'أُنهيت كل الجلسات',
        );
      default:
        return;
    }
    await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final e = employee;
    final active = e['active'] != false;
    final perms = (e['permissions'] as Map?) ?? const {};
    final sector = e['sector_code'] == null ? '-' : '${e['sector_code']} ${txt(e['sector_name'], '')}'.trim();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 0, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${txt(e['employee_code'])} - ${txt(e['full_name'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Wrap(spacing: 6, runSpacing: 4, children: [
                StatusChip(txt(e['role_label'] ?? e['role']), kTechColor),
                active ? StatusChip('فعّال', AppColors.good) : StatusChip('موقوف', AppColors.bad),
              ]),
              if (!active && e['suspended_reason'] != null)
                InfoLine(Icons.info_outline, 'سبب الإيقاف: ${e['suspended_reason']}', color: AppColors.bad),
              InfoLine(Icons.map, 'القاطع: $sector  •  المشرف: ${txt(e['supervisor_code'])}'),
              InfoLine(Icons.phone, 'الهاتف: ${txt(e['phone'])}'),
              InfoLine(
                Icons.devices,
                'أجهزة معتمدة: ${toInt(e['devices'])}  •  جلسات فعّالة: ${toInt(e['sessions'])}  •  آخر دخول: ${shortTs(e['last_login'])}',
              ),
              if (perms.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final p in perms.entries)
                    StatusChip(
                      '${switchLabels[p.key] ?? p.key}: ${p.value == true ? 'مسموح' : 'ممنوع'}',
                      p.value == true ? AppColors.brand : AppColors.bad,
                    ),
                ]),
              ],
            ]),
          ),
          PopupMenuButton<String>(
            tooltip: 'إجراءات',
            onSelected: (a) => _onAction(context, a),
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit), title: Text('تعديل'))),
              const PopupMenuItem(value: 'perms', child: ListTile(leading: Icon(Icons.toggle_on), title: Text('صلاحيات شخصية'))),
              if (active)
                const PopupMenuItem(value: 'suspend', child: ListTile(leading: Icon(Icons.block, color: AppColors.bad), title: Text('إيقاف الحساب'))),
              if (!active)
                const PopupMenuItem(
                    value: 'reactivate', child: ListTile(leading: Icon(Icons.check_circle, color: AppColors.good), title: Text('إعادة تفعيل'))),
              const PopupMenuItem(value: 'password', child: ListTile(leading: Icon(Icons.password), title: Text('تغيير كلمة المرور'))),
              const PopupMenuItem(value: 'logout', child: ListTile(leading: Icon(Icons.logout), title: Text('إنهاء كل الجلسات'))),
            ],
          ),
        ]),
      ),
    );
  }
}

// ================================================================ create / edit

/// Create (no [initial]) or edit an account. Returns the request body: for an edit only the changed fields
/// (an empty map when nothing changed); an empty sector / supervisor clears it.
class _EmployeeFormDialog extends StatefulWidget {
  final Map? initial;
  const _EmployeeFormDialog({this.initial});

  @override
  State<_EmployeeFormDialog> createState() => _EmployeeFormDialogState();
}

class _EmployeeFormDialogState extends State<_EmployeeFormDialog> {
  late final Map _i = widget.initial ?? const {};
  late final _code = TextEditingController();
  late final _password = TextEditingController();
  late final _name = TextEditingController(text: txt(_i['full_name'], ''));
  late final _phone = TextEditingController(text: txt(_i['phone'], ''));
  late final _sector = TextEditingController(text: txt(_i['sector_code'], ''));
  late final _supervisor = TextEditingController(text: txt(_i['supervisor_code'], ''));
  late String _role = techRoleLabels.containsKey(_i['role']) ? _i['role'] as String : 'collector';
  String? _error;

  bool get _isNew => widget.initial == null;

  @override
  void dispose() {
    for (final c in [_code, _password, _name, _phone, _sector, _supervisor]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fail(String message) => setState(() => _error = message);

  void _submit() {
    final name = _name.text.trim();
    if (name.length < 3) {
      _fail('الاسم 3 أحرف على الأقل');
      return;
    }
    final body = <String, dynamic>{};
    if (_isNew) {
      final code = _code.text.trim();
      if (code.length < 3) {
        _fail('رقم الموظف 3 أحرف على الأقل');
        return;
      }
      if (_password.text.length < 8) {
        _fail('كلمة المرور 8 أحرف على الأقل');
        return;
      }
      body['employee_code'] = code;
      body['full_name'] = name;
      body['role'] = _role;
      body['password'] = _password.text;
      if (_phone.text.trim().isNotEmpty) body['phone'] = _phone.text.trim();
      if (_sector.text.trim().isNotEmpty) body['sector_code'] = _sector.text.trim();
      if (_supervisor.text.trim().isNotEmpty) body['supervisor_code'] = _supervisor.text.trim();
    } else {
      void diff(String key, String value) {
        if (value != txt(_i[key], '')) body[key] = value;
      }

      diff('full_name', name);
      diff('phone', _phone.text.trim());
      diff('sector_code', _sector.text.trim());
      diff('supervisor_code', _supervisor.text.trim());
      if (_role != _i['role']) body['role'] = _role;
    }
    Navigator.pop(context, body);
  }

  Widget _field(TextEditingController c, String label, {bool obscure = false, TextInputType? keyboard, String? helper}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        obscureText: obscure,
        keyboardType: keyboard,
        decoration: InputDecoration(labelText: label, helperText: helper, border: const OutlineInputBorder(), isDense: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isNew ? 'موظف جديد' : 'تعديل ${txt(_i['employee_code'])}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_isNew) _field(_code, 'رقم الموظف (مثل JB-0500)'),
            _field(_name, 'الاسم الكامل'),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'الدور',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  helperText: _isNew ? null : 'تغيير الدور يُنهي جلسات الموظف',
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _role,
                    isDense: true,
                    isExpanded: true,
                    items: [for (final r in techRoleLabels.entries) DropdownMenuItem(value: r.key, child: Text(r.value))],
                    onChanged: (v) => setState(() => _role = v ?? _role),
                  ),
                ),
              ),
            ),
            if (_isNew) _field(_password, 'كلمة المرور (8 أحرف على الأقل)', obscure: true),
            _field(_phone, 'الهاتف', keyboard: TextInputType.phone),
            _field(_sector, 'رمز القاطع', helper: _isNew ? null : 'اتركه فارغاً لإزالة القاطع'),
            _field(_supervisor, 'رقم المشرف', helper: _isNew ? null : 'اتركه فارغاً لإزالة المشرف'),
            if (_error != null) NoticeBanner(tone: Tone.bad, title: _error!),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        ElevatedButton(onPressed: _submit, child: Text(_isNew ? 'إنشاء' : 'حفظ')),
      ],
    );
  }
}

// ================================================================ per-person switches

/// Tri-state per switch: default (null, follows global and sector), allowed (true), forbidden (false).
class _PermissionsDialog extends StatefulWidget {
  final String name;
  final Map current;
  const _PermissionsDialog({required this.name, required this.current});

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  late final Map<String, String> _state = {
    for (final k in switchLabels.keys)
      k: widget.current[k] == true ? 'allow' : (widget.current[k] == false ? 'deny' : 'default'),
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('صلاحيات شخصية - ${widget.name}'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('«افتراضي» يتبع المفتاح العام وإعداد القاطع. «ممنوع» يوقف الميزة لهذا الشخص فقط.',
                style: TextStyle(color: AppColors.muted, fontSize: 13)),
            for (final e in switchLabels.entries) ...[
              const SizedBox(height: 12),
              Text(e.value, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'default', label: Text('افتراضي')),
                    ButtonSegment(value: 'allow', label: Text('مسموح')),
                    ButtonSegment(value: 'deny', label: Text('ممنوع')),
                  ],
                  selected: {_state[e.key]!},
                  onSelectionChanged: (s) => setState(() => _state[e.key] = s.first),
                ),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        ElevatedButton(
          onPressed: () => Navigator.pop<Map<String, bool?>>(context, {
            for (final e in _state.entries) e.key: e.value == 'allow' ? true : (e.value == 'deny' ? false : null),
          }),
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}
