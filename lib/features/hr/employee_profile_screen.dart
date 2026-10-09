import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/photo_service.dart';
import '../../core/theme.dart';
import '../self_service/self_service_screen.dart' show showPayslip;
import '../shared/photo_dialog.dart';
import '../shared/ui.dart';
import 'employee_form.dart';

/// One employee's full HR file with actions: edit, documents, custody, discipline, terminate/reactivate.
class EmployeeProfileScreen extends StatefulWidget {
  final String code;
  const EmployeeProfileScreen({super.key, required this.code});

  @override
  State<EmployeeProfileScreen> createState() => _EmployeeProfileScreenState();
}

class _EmployeeProfileScreenState extends State<EmployeeProfileScreen> {
  final _view = GlobalKey<ApiViewState>();

  void _reload() => _view.currentState?.reload();

  Future<void> _edit(Map<String, dynamic> profile) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => EmployeeFormScreen(existing: profile)));
    if (changed == true) _reload();
  }

  Future<void> _addDocument() async {
    String type = 'national_id';
    final title = TextEditingController();
    DateTime? expires;
    CapturedPhoto? file;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('إضافة وثيقة'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'النوع', border: OutlineInputBorder()),
              items: const {
                'national_id': 'البطاقة الوطنية',
                'contract': 'العقد',
                'guarantee': 'كفالة',
                'certificate': 'شهادة',
                'medical': 'تقرير طبي',
                'other': 'أخرى',
              }.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => setD(() => type = v ?? 'other'),
            ),
            const SizedBox(height: 10),
            TextField(controller: title, decoration: const InputDecoration(labelText: 'العنوان', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.event),
              label: Text('تاريخ الانتهاء: ${expires == null ? '-' : apiDate(expires!)}'),
              onPressed: () async {
                final d = await showDatePicker(context: ctx, initialDate: DateTime.now(), firstDate: DateTime(2000), lastDate: DateTime(2100));
                if (d != null) setD(() => expires = d);
              },
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.camera_alt),
              label: Text(file == null ? 'تصوير / اختيار صورة' : 'تم الإرفاق ✔'),
              onPressed: () async {
                final p = await PhotoService.capture();
                if (p != null) setD(() => file = p);
              },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ')),
          ],
        ),
      ),
    );
    final t = title.text.trim();
    Future.delayed(const Duration(milliseconds: 400), title.dispose);
    if (ok != true || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/hr/employees/${widget.code}/documents', {
          'doc_type': type,
          'title': t.isEmpty ? type : t,
          'file_base64': file?.base64,
          'expires_on': expires == null ? null : apiDate(expires!),
        }), success: 'تمت إضافة الوثيقة');
    _reload();
  }

  Future<void> _assignCustody() async {
    String type = 'phone';
    final desc = TextEditingController();
    final serial = TextEditingController();
    final value = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('تسليم عهدة'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'النوع', border: OutlineInputBorder()),
              items: custodyTypeLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => setD(() => type = v ?? 'other'),
            ),
            const SizedBox(height: 10),
            TextField(controller: desc, decoration: const InputDecoration(labelText: 'الوصف (مثال: Samsung A15)', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: serial, decoration: const InputDecoration(labelText: 'الرقم التسلسلي / IMEI', border: OutlineInputBorder())),
            const SizedBox(height: 10),
            TextField(controller: value, keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'القيمة (د.ع)', border: OutlineInputBorder())),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تسليم')),
          ],
        ),
      ),
    );
    final d = desc.text.trim(), s = serial.text.trim(), v = double.tryParse(value.text.replaceAll(',', '').trim()) ?? 0;
    Future.delayed(const Duration(milliseconds: 400), () {
      desc.dispose();
      serial.dispose();
      value.dispose();
    });
    if (ok != true || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/hr/custody', {
          'employee_code': widget.code,
          'item_type': type,
          'description': d.isEmpty ? (custodyTypeLabels[type] ?? type) : d,
          'serial_no': s.isEmpty ? null : s,
          'value_iqd': v,
        }), success: 'تم تسليم العهدة');
    _reload();
  }

  Future<void> _returnCustody(Map c) async {
    String outcome = 'returned';
    bool charge = false;
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('تسوية عهدة: ${c['description']}'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'returned', label: Text('أُعيدت')), ButtonSegment(value: 'lost', label: Text('مفقودة'))],
              selected: {outcome},
              onSelectionChanged: (s) => setD(() => outcome = s.first),
            ),
            if (outcome == 'lost')
              CheckboxListTile(
                value: charge,
                onChanged: (v) => setD(() => charge = v ?? false),
                title: Text('خصم القيمة (${formatIqd(asNum(c['value_iqd']))}) من الراتب'),
              ),
            const SizedBox(height: 8),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظة', border: OutlineInputBorder())),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تأكيد')),
          ],
        ),
      ),
    );
    final n = note.text.trim();
    Future.delayed(const Duration(milliseconds: 400), note.dispose);
    if (ok != true || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/hr/custody/${c['id']}/return',
        {'outcome': outcome, 'note': n.isEmpty ? null : n, 'charge_employee': charge}));
    _reload();
  }

  Future<void> _discipline() async {
    String type = 'written_warning';
    final reason = TextEditingController();
    final penalty = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('إجراء انضباطي'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'نوع الإجراء', border: OutlineInputBorder()),
              items: disciplineLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => setD(() => type = v ?? 'written_warning'),
            ),
            const SizedBox(height: 10),
            TextField(controller: reason, maxLines: 2, decoration: const InputDecoration(labelText: 'السبب (إلزامي)', border: OutlineInputBorder())),
            if (type == 'penalty') ...[
              const SizedBox(height: 10),
              TextField(controller: penalty, keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'مبلغ العقوبة (يُخصم من الراتب)', border: OutlineInputBorder())),
            ],
            if (type == 'suspension')
              const Padding(padding: EdgeInsets.only(top: 8), child: Text('سيتم إيقاف حساب الموظف فوراً', style: TextStyle(color: AppColors.bad))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تسجيل')),
          ],
        ),
      ),
    );
    final r = reason.text.trim(), p = double.tryParse(penalty.text.replaceAll(',', '').trim()) ?? 0;
    Future.delayed(const Duration(milliseconds: 400), () {
      reason.dispose();
      penalty.dispose();
    });
    if (ok != true || !mounted) return;
    final res = await runApi(context, () => ApiClient.instance.post('/hr/discipline',
        {'employee_code': widget.code, 'action_type': type, 'reason': r, 'penalty_iqd': p}), success: 'تم تسجيل الإجراء');
    if (res != null && res['suspension_recommended'] == true && mounted) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.warning, color: AppColors.bad),
          title: const Text('تنبيه'),
          content: Text('لدى الموظف ${res['written_warnings_12m']} إنذارات كتابية خلال 12 شهراً. يُنصح بالإيقاف عن العمل.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('حسناً'))],
        ),
      );
    }
    _reload();
  }

  Future<void> _terminate(bool active) async {
    if (active) {
      final reason = await askNote(context, 'إنهاء خدمة الموظف', required: true, label: 'السبب');
      if (reason == null || !mounted) return;
      await runApi(context, () => ApiClient.instance.post('/hr/employees/${widget.code}/terminate', {'reason': reason}),
          success: 'تم إنهاء الخدمة');
    } else {
      await runApi(context, () => ApiClient.instance.post('/hr/employees/${widget.code}/reactivate'), success: 'تم تفعيل الحساب');
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: portalAppBar(title: 'ملف الموظف ${widget.code}', color: AppColors.hr),
      body: ApiView(
        key: _view,
        path: '/hr/employees/${widget.code}',
        builder: (context, data, reload) {
          final p = Map<String, dynamic>.from(data['profile'] as Map);
          final active = p['active'] == true;
          final balances = data['leave_balances'] as Map;
          final att = data['attendance_month'] as Map;
          final docs = (data['documents'] as List).cast<Map>();
          final custody = (data['custody'] as List).cast<Map>();
          final disc = (data['discipline'] as List).cast<Map>();
          final leaves = (data['leave_requests'] as List).cast<Map>();
          final apps = (data['appraisals'] as List).cast<Map>();
          final training = (data['training'] as List).cast<Map>();
          final slips = (data['payslips'] as List).cast<Map>();
          return RefreshIndicator(
            onRefresh: reload,
            child: ListView(
              padding: const EdgeInsets.all(Gap.md),
              children: [
                AppCard(
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        CircleAvatar(radius: 28, backgroundColor: active ? AppColors.hr.withValues(alpha: 0.10) : AppColors.border,
                            child: Icon(Icons.person, size: 32, color: active ? AppColors.hr : AppColors.muted)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${p['full_name']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                            Text('${p['employee_code']} | ${p['job_title'] ?? roleLabels[p['role']] ?? ''} | ${p['sector_name'] ?? 'بدون قاطع'}'),
                            Text('المشرف: ${p['supervisor_name'] ?? '-'} | المباشرة: ${p['hire_date'] ?? '-'} | نهاية العقد: ${p['contract_end'] ?? '-'}',
                                style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                          ]),
                        ),
                        StatusChip(active ? 'فعال' : 'موقوف', active ? AppColors.good : AppColors.bad),
                      ]),
                      const Divider(height: 24),
                      Wrap(spacing: 20, runSpacing: 8, children: [
                        Text('الهاتف: ${p['phone'] ?? '-'}'),
                        Text('البطاقة الوطنية: ${p['national_id_no'] ?? '-'}'),
                        Text('الطوارئ: ${p['emergency_contact'] ?? '-'}'),
                        Text('الراتب: ${formatIqd(asNum(p['base_salary']))}'),
                        Text('البدلات: ${formatIqd((asNum(p['allowance_transport']) ?? 0) + (asNum(p['allowance_phone']) ?? 0) + (asNum(p['allowance_risk']) ?? 0))}'),
                        if ((asNum(data['cash_in_hand']) ?? 0) > 0) Text('نقد غير مسلَّم: ${formatIqd(asNum(data['cash_in_hand']))}',
                            style: const TextStyle(color: AppColors.bad)),
                      ]),
                      if (p['hr_notes'] != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('ملاحظات: ${p['hr_notes']}')),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        ElevatedButton.icon(onPressed: () => _edit(p), icon: const Icon(Icons.edit), label: const Text('تعديل')),
                        OutlinedButton.icon(onPressed: _addDocument, icon: const Icon(Icons.upload_file), label: const Text('وثيقة')),
                        OutlinedButton.icon(onPressed: _assignCustody, icon: const Icon(Icons.inventory_2), label: const Text('تسليم عهدة')),
                        OutlinedButton.icon(onPressed: _discipline, icon: const Icon(Icons.gavel), label: const Text('إجراء انضباطي')),
                        OutlinedButton.icon(
                          onPressed: () => _terminate(active),
                          icon: Icon(active ? Icons.person_off : Icons.person_add),
                          label: Text(active ? 'إنهاء الخدمة' : 'إعادة تفعيل'),
                          style: OutlinedButton.styleFrom(foregroundColor: active ? AppColors.bad : AppColors.good),
                        ),
                      ]),
                    ]),
                ),
                const SectionTitle('هذا الشهر'),
                Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                  _mini('أيام الحضور', '${att['present']}', AppColors.good),
                  _mini('أيام التأخير', '${att['late']}', AppColors.warn),
                  _mini('ساعات العمل', '${att['hours']}', AppColors.info),
                  ...balances.values.map((b) {
                    final m = b as Map;
                    return _mini(m['label'] as String, m['remaining'] == null ? '${m['used']} مستخدم' : '${m['remaining']} متبقي', AppColors.hr);
                  }),
                ]),
                const SectionTitle('الوثائق'),
                if (docs.isEmpty) const Text('لا توجد وثائق', style: TextStyle(color: AppColors.muted)),
                ...docs.map((d) {
                  final exp = DateTime.tryParse('${d['expires_on'] ?? ''}');
                  final soon = exp != null && exp.difference(DateTime.now()).inDays <= 30;
                  return Card(child: ListTile(
                    leading: const Icon(Icons.description),
                    title: Text('${d['title']}'),
                    subtitle: Text('${d['doc_type']} | ينتهي: ${d['expires_on'] ?? '-'}', style: TextStyle(color: soon ? AppColors.bad : null)),
                    trailing: d['has_file'] == true
                        ? IconButton(icon: const Icon(Icons.visibility), onPressed: () => showEvidencePhoto(context, '/hr/documents/${d['id']}/file', title: '${d['title']}'))
                        : null,
                  ));
                }),
                const SectionTitle('العهدة'),
                if (custody.isEmpty) const Text('لا توجد عهدة مسلّمة لهذا الموظف', style: TextStyle(color: AppColors.muted)),
                ...custody.map((c) => Card(child: ListTile(
                      leading: const Icon(Icons.inventory_2),
                      title: Text('${custodyTypeLabels[c['item_type']] ?? c['item_type']} - ${c['description']}'),
                      subtitle: Text('${c['serial_no'] ?? ''} | ${formatIqd(asNum(c['value_iqd']))} | سُلّمت ${formatDate(c['assigned_at'])}'),
                      trailing: c['status'] == 'assigned'
                          ? TextButton(onPressed: () => _returnCustody(c), child: const Text('تسوية'))
                          : StatusChip(c['status'] == 'returned' ? 'أُعيدت' : 'مفقودة', statusTone(c['status'] as String?)),
                    ))),
                const SectionTitle('الإجراءات الانضباطية'),
                if (disc.isEmpty) const Text('لا توجد إجراءات انضباطية', style: TextStyle(color: AppColors.muted)),
                ...disc.map((d) => Card(child: ListTile(
                      leading: const Icon(Icons.gavel, color: AppColors.bad),
                      title: Text('${disciplineLabels[d['action_type']] ?? d['action_type']}${(asNum(d['penalty_iqd']) ?? 0) > 0 ? ' | ${formatIqd(asNum(d['penalty_iqd']))}' : ''}'),
                      subtitle: Text('${d['effective_date']} | ${d['reason']}'),
                    ))),
                const SectionTitle('الإجازات'),
                if (leaves.isEmpty) const Text('لا توجد إجازات مسجلة', style: TextStyle(color: AppColors.muted)),
                ...leaves.map((l) => Card(child: ListTile(
                      title: Text('${l['label']} | ${l['days']} يوم'),
                      subtitle: Text('${l['start_date']} ← ${l['end_date']}'),
                      trailing: StatusChip(leaveStatusLabels[l['status']] ?? '${l['status']}', statusTone(l['status'] as String?)),
                    ))),
                const SectionTitle('التقييمات والتدريب والرواتب'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  ...apps.map((a) => Chip(label: Text('${a['period']}: ${(asNum(a['final_score']) ?? 0).round()} / 100'))),
                  ...training.map((t) => Chip(
                        avatar: Icon(t['status'] == 'completed' ? Icons.verified : Icons.school, size: 16),
                        label: Text('${t['title']}'),
                      )),
                  ...slips.map((s) => ActionChip(
                        avatar: const Icon(Icons.request_quote, size: 16),
                        label: Text('${s['period']}: ${formatIqd(asNum(s['net']))}'),
                        onPressed: () async {
                          final run = await runApi(context, () => ApiClient.instance.get('/hr/payroll/runs/${s['period']}'));
                          if (run == null || !context.mounted) return;
                          final slip = (run['payslips'] as List).cast<Map>().firstWhere((x) => x['id'] == s['id'], orElse: () => {});
                          if (slip.isNotEmpty) showPayslip(context, '', preloaded: {...slip, 'period': s['period']});
                        },
                      )),
                ]),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _mini(String label, String value, Color color) {
    return Container(
      width: 150,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(Gap.radius),
        border: const Border(
          top: BorderSide(color: AppColors.border),
          bottom: BorderSide(color: AppColors.border),
          left: BorderSide(color: AppColors.border),
          right: BorderSide(color: AppColors.border),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 16)),
      ]),
    );
  }
}
