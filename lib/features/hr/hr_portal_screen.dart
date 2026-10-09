import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../self_service/self_service_screen.dart' show SelfServiceButton;
import '../shared/ui.dart';
import '../finance/charts.dart' show KpiCard;
import 'employee_form.dart';
import 'employee_profile_screen.dart';
import 'hr_tabs.dart';

const _hrColor = AppColors.hr;

/// HR portal (role hr, admin). Supervisors and finance reuse some of the tabs from hr_tabs.dart.
class HrPortalScreen extends StatelessWidget {
  const HrPortalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 10,
      child: Scaffold(
        appBar: portalAppBar(
          title: 'الموارد البشرية',
          subtitle: Session.instance.fullName,
          color: _hrColor,
          actions: const [SelfServiceButton(), LogoutButton()],
          bottom: portalTabBar(const [
              Tab(icon: Icon(Icons.dashboard), text: 'لوحة القيادة'),
              Tab(icon: Icon(Icons.people), text: 'الموظفون'),
              Tab(icon: Icon(Icons.fingerprint), text: 'الحضور'),
              Tab(icon: Icon(Icons.beach_access), text: 'الإجازات'),
              Tab(icon: Icon(Icons.payments), text: 'الرواتب'),
              Tab(icon: Icon(Icons.receipt_long), text: 'المصاريف'),
              Tab(icon: Icon(Icons.star), text: 'التقييم'),
              Tab(icon: Icon(Icons.inventory_2), text: 'العهد'),
              Tab(icon: Icon(Icons.person_add), text: 'التوظيف'),
              Tab(icon: Icon(Icons.school), text: 'التدريب'),
          ]),
        ),
        body: const TabBarView(children: [
          _DashboardTab(),
          _EmployeesTab(),
          AttendanceDayTab(),
          LeaveApprovalsTab(),
          PayrollTab(),
          ExpenseApprovalsTab(),
          AppraisalsTab(),
          _CustodyTab(),
          _RecruitmentTab(),
          _TrainingTab(),
        ]),
      ),
    );
  }
}

// ================================================================ dashboard

class _DashboardTab extends StatelessWidget {
  const _DashboardTab();

  Widget _kpi(String label, String value, IconData icon, Color color) =>
      KpiCard(label: label, value: value, icon: icon, color: color, width: 210);

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/hr/dashboard',
      builder: (context, d, reload) {
        final headcount = (d['headcount'] as List).cast<Map>();
        final expiring = (d['expiring'] as List).cast<Map>();
        final last = d['last_payroll'] as Map?;
        final totalActive = headcount.fold<int>(0, (s, r) => s + ((asNum(r['active']) ?? 0).toInt()));
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              Text('اليوم ${d['today']}${d['working_day'] == true ? '' : ' (عطلة)'}', style: const TextStyle(color: AppColors.muted)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _kpi('موظف فعال', '$totalActive', Icons.people, _hrColor),
                _kpi('حاضر اليوم', '${d['present_today']}', Icons.how_to_reg, AppColors.good),
                _kpi('متأخر اليوم', '${d['late_today']}', Icons.schedule, AppColors.warn),
                _kpi('غائب من الميدان', '${d['absent_field_today']}', Icons.person_off, AppColors.bad),
                _kpi('في إجازة', '${d['on_leave_today']}', Icons.beach_access, AppColors.info),
                _kpi('إجازات بانتظار الموارد', '${d['leave_pending_hr']}', Icons.pending_actions, AppColors.warn),
                _kpi('إجازات بانتظار المشرفين', '${d['leave_pending_supervisor']}', Icons.hourglass_top, AppColors.warn),
                _kpi('مصاريف معلقة', '${d['expenses_pending']} | ${formatIqd(asNum(d['expenses_pending_amount']))}', Icons.receipt_long, AppColors.muted),
                _kpi('عهد لدى الموظفين', '${d['custody_items_out']} | ${formatIqd(asNum(d['custody_value_out']))}', Icons.inventory_2, AppColors.brand),
                _kpi('تحصيل الشهر', formatIqd(asNum(d['collected_this_month'])), Icons.account_balance_wallet, AppColors.brand),
              ]),
              const SectionTitle('الملاك حسب الدور'),
              Wrap(spacing: 8, runSpacing: 8, children: headcount
                  .map((r) => Chip(label: Text('${roleLabels[r['role']] ?? r['role']}: ${r['active']} فعال'
                      '${(asNum(r['inactive']) ?? 0) > 0 ? ' / ${r['inactive']} موقوف' : ''}')))
                  .toList()),
              const SectionTitle('آخر رواتب'),
              if (last == null)
                const EmptyState(icon: Icons.payments_outlined, title: 'لم تحتسب أي رواتب بعد', message: 'احتسب رواتب الشهر من تبويب «الرواتب»')
              else
                AppCard(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Row(children: [
                    Expanded(child: Text('${last['period']}', style: const TextStyle(fontWeight: FontWeight.w600))),
                    StatusChip(
                      last['status'] == 'draft' ? 'مسودة' : (last['status'] == 'approved' ? 'معتمدة' : 'مصروفة'),
                      last['status'] == 'draft' ? AppColors.warn : AppColors.good,
                    ),
                    const SizedBox(width: Gap.md),
                    Text('الصافي ${formatIqd(asNum((last['totals'] as Map?)?['net']))}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontFeatures: [FontFeature.tabularFigures()])),
                  ]),
                ),
              SectionTitle('عقود ووثائق تنتهي خلال 30 يوماً (${expiring.length})'),
              if (expiring.isEmpty) const EmptyState(icon: Icons.event_available, title: 'لا توجد عقود أو وثائق تنتهي قريباً'),
              ...expiring.map((x) => AppCard(
                    accent: AppColors.warn,
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(x['kind'] == 'contract' ? Icons.description : Icons.badge, color: AppColors.warn),
                      title: Text('${x['ref']} - ${x['title']}'),
                      subtitle: Text('${x['kind'] == 'contract' ? 'نهاية العقد' : 'انتهاء الوثيقة'}: ${x['expires_on']}'),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmployeeProfileScreen(code: '${x['ref']}'))),
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ employees

class _EmployeesTab extends StatefulWidget {
  const _EmployeesTab();

  @override
  State<_EmployeesTab> createState() => _EmployeesTabState();
}

class _EmployeesTabState extends State<_EmployeesTab> {
  final _q = TextEditingController();
  String _query = '';
  String? _role;
  bool _activeOnly = true;
  final _view = GlobalKey<ApiViewState>();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  String get _path {
    final p = <String>[];
    if (_query.isNotEmpty) p.add('q=${Uri.encodeQueryComponent(_query)}');
    if (_role != null) p.add('role=$_role');
    if (_activeOnly) p.add('active=true');
    return '/hr/employees${p.isEmpty ? '' : '?${p.join('&')}'}';
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 260,
            child: TextField(
              controller: _q,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'بحث بالاسم أو الرقم', border: OutlineInputBorder(), isDense: true),
              onSubmitted: (v) => setState(() => _query = v.trim()),
            ),
          ),
          DropdownButton<String?>(
            value: _role,
            hint: const Text('كل الأدوار'),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('كل الأدوار')),
              ...roleLabels.entries.map((e) => DropdownMenuItem<String?>(value: e.key, child: Text(e.value))),
            ],
            onChanged: (v) => setState(() => _role = v),
          ),
          FilterChip(label: const Text('الفعالون فقط'), selected: _activeOnly, onSelected: (v) => setState(() => _activeOnly = v)),
          ElevatedButton.icon(
            onPressed: () => _open(const EmployeeFormScreen()),
            icon: const Icon(Icons.person_add),
            label: const Text('موظف جديد'),
          ),
        ]),
      ),
      Expanded(
        child: ApiView(
          key: _view,
          path: _path,
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            if (list.isEmpty) return const EmptyState(icon: Icons.person_search, title: 'لا يوجد موظفون مطابقون', message: 'جرّب تغيير البحث أو الفلتر');
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                children: [
                  Text('${list.length} موظف', style: const TextStyle(color: AppColors.muted)),
                  ...list.map((e) {
                    final active = e['active'] == true;
                    final today = e['on_leave'] == true
                        ? const StatusChip('إجازة', AppColors.info)
                        : (e['checked_in_at'] != null ? StatusChip('حاضر ${formatTime(e['checked_in_at'])}', statusTone('present')) : null);
                    return Card(
                      color: active ? null : AppColors.paper,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: active ? _hrColor.withValues(alpha: 0.12) : AppColors.border,
                          child: Icon(Icons.person, color: active ? _hrColor : AppColors.muted),
                        ),
                        title: Text('${e['employee_code']} - ${e['full_name']}'),
                        subtitle: Text('${roleLabels[e['role']] ?? e['role']}${e['job_title'] != null ? ' | ${e['job_title']}' : ''}'
                            '${e['sector_name'] != null ? ' | ${e['sector_name']}' : ''}'
                            '${e['contract_end'] != null ? ' | العقد حتى ${e['contract_end']}' : ''}'),
                        trailing: active ? today : const StatusChip('موقوف / منتهي', AppColors.muted),
                        onTap: () => _open(EmployeeProfileScreen(code: '${e['employee_code']}')),
                      ),
                    );
                  }),
                ],
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ================================================================ custody

class _CustodyTab extends StatefulWidget {
  const _CustodyTab();

  @override
  State<_CustodyTab> createState() => _CustodyTabState();
}

class _CustodyTabState extends State<_CustodyTab> {
  String _status = 'assigned';
  final _view = GlobalKey<ApiViewState>();

  Future<void> _settle(Map c) async {
    String outcome = 'returned';
    bool charge = false;
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('تسوية عهدة: ${c['description']}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'returned', label: Text('أُعيدت')), ButtonSegment(value: 'lost', label: Text('مفقودة/تالفة'))],
              selected: {outcome},
              onSelectionChanged: (s) => setD(() => outcome = s.first),
            ),
            if (outcome == 'lost' && (asNum(c['value_iqd']) ?? 0) > 0)
              CheckboxListTile(
                value: charge,
                onChanged: (v) => setD(() => charge = v ?? false),
                title: Text('استقطاع القيمة (${formatIqd(asNum(c['value_iqd']))}) من الراتب'),
              ),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظة')),
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
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'assigned', label: Text('لدى الموظفين')),
              ButtonSegment(value: 'returned', label: Text('أُعيدت')),
              ButtonSegment(value: 'lost', label: Text('مفقودة')),
              ButtonSegment(value: 'all', label: Text('الكل')),
            ],
            selected: {_status},
            onSelectionChanged: (s) => setState(() => _status = s.first),
          ),
          const SizedBox(height: 4),
          const Text('لتسليم عهدة جديدة افتح ملف الموظف من تبويب الموظفين.', style: TextStyle(color: AppColors.muted, fontSize: 12)),
        ]),
      ),
      Expanded(
        child: ApiView(
          key: _view,
          path: '/hr/custody?status=$_status',
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            if (list.isEmpty) return const EmptyState(icon: Icons.inventory_2_outlined, title: 'لا توجد عهد بهذه الحالة');
            final total = list.fold<double>(0, (s, c) => s + (asNum(c['value_iqd']) ?? 0).toDouble());
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                children: [
                  Text('${list.length} عهدة | القيمة ${formatIqd(total)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ...list.map((c) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.inventory_2),
                          title: Text('${custodyTypeLabels[c['item_type']] ?? c['item_type']}: ${c['description']}'
                              '${c['serial_no'] != null ? ' (${c['serial_no']})' : ''}'),
                          subtitle: Text('${c['employee_code']} - ${c['full_name']} | ${formatIqd(asNum(c['value_iqd']))} | '
                              'سُلّمت ${formatDate(c['assigned_at'])}${c['returned_at'] != null ? ' | سُوّيت ${formatDate(c['returned_at'])}' : ''}'),
                          trailing: c['status'] == 'assigned'
                              ? OutlinedButton(onPressed: () => _settle(c), child: const Text('تسوية'))
                              : StatusChip(c['status'] == 'returned' ? 'أُعيدت' : 'مفقودة', statusTone(c['status'] as String?)),
                        ),
                      )),
                ],
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ================================================================ recruitment

const _stageLabels = {
  'applied': 'متقدم',
  'interview': 'مقابلة',
  'test': 'اختبار',
  'offer': 'عرض عمل',
  'hired': 'تم التعيين',
  'rejected': 'مرفوض',
};

class _RecruitmentTab extends StatefulWidget {
  const _RecruitmentTab();

  @override
  State<_RecruitmentTab> createState() => _RecruitmentTabState();
}

class _RecruitmentTabState extends State<_RecruitmentTab> {
  final _view = GlobalKey<ApiViewState>();

  void _reload() => _view.currentState?.reload();

  Future<void> _newOpening() async {
    final title = TextEditingController();
    final positions = TextEditingController(text: '1');
    final desc = TextEditingController();
    String role = 'collector';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('وظيفة شاغرة جديدة'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'عنوان الوظيفة')),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: const InputDecoration(labelText: 'الدور'),
                items: const ['collector', 'supervisor', 'finance', 'hr']
                    .map((r) => DropdownMenuItem(value: r, child: Text(roleLabels[r] ?? r)))
                    .toList(),
                onChanged: (v) => setD(() => role = v ?? role),
              ),
              TextField(controller: positions, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'عدد الشواغر')),
              TextField(controller: desc, maxLines: 2, decoration: const InputDecoration(labelText: 'الوصف (اختياري)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('نشر')),
          ],
        ),
      ),
    );
    final body = {
      'title': title.text.trim(),
      'role': role,
      'positions': int.tryParse(positions.text.trim()) ?? 1,
      'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
    };
    Future.delayed(const Duration(milliseconds: 400), () {
      title.dispose();
      positions.dispose();
      desc.dispose();
    });
    if (ok != true || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/hr/openings', body), success: 'تم نشر الوظيفة');
    _reload();
  }

  Future<void> _addApplicant(Map o) async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('متقدم جديد: ${o['title']}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'الاسم الكامل')),
          TextField(controller: phone, decoration: const InputDecoration(labelText: 'الهاتف (07...)')),
          TextField(controller: notes, decoration: const InputDecoration(labelText: 'ملاحظات')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إضافة')),
        ],
      ),
    );
    final body = {
      'opening_id': o['id'],
      'full_name': name.text.trim(),
      'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
      'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
    };
    Future.delayed(const Duration(milliseconds: 400), () {
      name.dispose();
      phone.dispose();
      notes.dispose();
    });
    if (ok != true || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/hr/applicants', body));
    _reload();
  }

  Future<void> _stage(Map a, String stage) async {
    final note = stage == 'rejected' ? await askNote(context, 'سبب الرفض') : '';
    if (note == null || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/hr/applicants/${a['id']}/stage', {'stage': stage, if (note.isNotEmpty) 'notes': note}));
    _reload();
  }

  Future<void> _hire(Map a) async {
    final code = TextEditingController();
    final pass = TextEditingController();
    final salary = TextEditingController();
    List<Map> sectors = [];
    try {
      sectors = ((await ApiClient.instance.get('/sectors')) as List).cast<Map>();
    } on ApiException catch (_) {}
    if (!mounted) return;
    String? sector;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('تعيين ${a['full_name']}'),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: code, decoration: const InputDecoration(labelText: 'رقم الموظف الجديد (مثال JB-0500)')),
              TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'كلمة مرور أولية (8 أحرف على الأقل)')),
              TextField(controller: salary, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الراتب الأساسي')),
              DropdownButtonFormField<String>(
                initialValue: sector,
                decoration: const InputDecoration(labelText: 'القاطع (اختياري)'),
                items: sectors.map((s) => DropdownMenuItem(value: '${s['code']}', child: Text('${s['code']} - ${s['name']}'))).toList(),
                onChanged: (v) => setD(() => sector = v),
              ),
              const SizedBox(height: 8),
              const Text('يُنشأ حساب الموظف وتُسند له الدورات الإلزامية. أكمل باقي الملف من صفحة الموظف.',
                  style: TextStyle(fontSize: 12, color: AppColors.muted)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تعيين')),
          ],
        ),
      ),
    );
    final body = {
      'employee_code': code.text.trim(),
      'password': pass.text,
      'base_salary': double.tryParse(salary.text.trim().replaceAll(',', '')) ?? 0,
      'sector_code': sector,
    };
    Future.delayed(const Duration(milliseconds: 400), () {
      code.dispose();
      pass.dispose();
      salary.dispose();
    });
    if (ok != true || !mounted) return;
    final res = await runApi(context, () => ApiClient.instance.post('/hr/applicants/${a['id']}/hire', body));
    _reload();
    if (res != null && mounted) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmployeeProfileScreen(code: '${res['employee_code']}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/hr/openings',
      builder: (context, data, reload) {
        final list = (data as List).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ElevatedButton.icon(onPressed: _newOpening, icon: const Icon(Icons.add), label: const Text('وظيفة شاغرة جديدة')),
              ),
              if (list.isEmpty) const EmptyState(icon: Icons.work_outline, title: 'لا توجد وظائف شاغرة', message: 'أضف وظيفة شاغرة لبدء استقبال المتقدمين'),
              ...list.map((o) {
                final pipeline = (o['pipeline'] as List).cast<Map>();
                final open = o['status'] == 'open';
                return Card(
                  child: ExpansionTile(
                    initiallyExpanded: open,
                    title: Text('${o['title']} (${roleLabels[o['role']] ?? o['role']})'),
                    subtitle: Text('الشواغر ${o['positions']} | المعيّنون ${o['hired']} | المتقدمون ${o['applicants']}'),
                    trailing: StatusChip(open ? 'مفتوحة' : 'مغلقة', open ? AppColors.good : AppColors.muted),
                    childrenPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    children: [
                      Wrap(spacing: 8, children: [
                        if (open) OutlinedButton.icon(onPressed: () => _addApplicant(o), icon: const Icon(Icons.person_add), label: const Text('إضافة متقدم')),
                        TextButton(
                          onPressed: () async {
                            await runApi(context, () => ApiClient.instance.post('/hr/openings/${o['id']}/status', {'status': open ? 'closed' : 'open'}));
                            _reload();
                          },
                          child: Text(open ? 'إغلاق الوظيفة' : 'إعادة فتح'),
                        ),
                      ]),
                      if (pipeline.isEmpty) const EmptyState(title: 'لا يوجد متقدمون'),
                      ...pipeline.map((a) {
                        final done = a['stage'] == 'hired' || a['stage'] == 'rejected';
                        return ListTile(
                          dense: true,
                          title: Text('${a['full_name']}${a['phone'] != null ? ' | ${a['phone']}' : ''}'),
                          subtitle: a['notes'] != null ? Text('${a['notes']}') : null,
                          leading: StatusChip(_stageLabels[a['stage']] ?? '${a['stage']}',
                              a['stage'] == 'hired' ? AppColors.good : (a['stage'] == 'rejected' ? AppColors.bad : AppColors.warn)),
                          trailing: done
                              ? null
                              : Wrap(spacing: 4, children: [
                                  PopupMenuButton<String>(
                                    tooltip: 'نقل إلى مرحلة',
                                    icon: const Icon(Icons.swap_horiz),
                                    onSelected: (s) => _stage(a, s),
                                    itemBuilder: (_) => const ['applied', 'interview', 'test', 'offer', 'rejected']
                                        .where((s) => s != a['stage'])
                                        .map((s) => PopupMenuItem(value: s, child: Text(_stageLabels[s]!)))
                                        .toList(),
                                  ),
                                  if (open)
                                    ElevatedButton(
                                      onPressed: () => _hire(a),
                                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.good, foregroundColor: Colors.white),
                                      child: const Text('تعيين'),
                                    ),
                                ]),
                        );
                      }),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ training

class _TrainingTab extends StatefulWidget {
  const _TrainingTab();

  @override
  State<_TrainingTab> createState() => _TrainingTabState();
}

class _TrainingTabState extends State<_TrainingTab> {
  final _view = GlobalKey<ApiViewState>();

  void _reload() => _view.currentState?.reload();

  Future<void> _newCourse() async {
    final title = TextEditingController();
    final desc = TextEditingController();
    String? mandatory;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('دورة تدريبية جديدة'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'عنوان الدورة')),
              TextField(controller: desc, maxLines: 2, decoration: const InputDecoration(labelText: 'الوصف')),
              DropdownButtonFormField<String?>(
                initialValue: mandatory,
                decoration: const InputDecoration(labelText: 'إلزامية لدور (تُسند تلقائياً)'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('اختيارية')),
                  ...const ['collector', 'supervisor', 'finance', 'hr', 'command']
                      .map((r) => DropdownMenuItem<String?>(value: r, child: Text(roleLabels[r] ?? r))),
                ],
                onChanged: (v) => setD(() => mandatory = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إنشاء')),
          ],
        ),
      ),
    );
    final body = {
      'title': title.text.trim(),
      'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
      'mandatory_for': mandatory,
    };
    Future.delayed(const Duration(milliseconds: 400), () {
      title.dispose();
      desc.dispose();
    });
    if (ok != true || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/hr/training/courses', body), success: 'تم إنشاء الدورة');
    _reload();
  }

  Future<void> _assign(Map c) async {
    final codes = await askNote(context, 'إسناد "${c['title']}"', required: true, label: 'أرقام الموظفين مفصولة بفاصلة');
    if (codes == null || !mounted) return;
    final list = codes.split(RegExp(r'[,،\s]+')).where((s) => s.isNotEmpty).toList();
    final res = await runApi(context, () => ApiClient.instance.post('/hr/training/courses/${c['id']}/assign', {'employee_codes': list}));
    if (res != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('أُسندت إلى ${res['assigned']} موظف')));
    }
    _reload();
  }

  Future<void> _complete(Map r) async {
    final s = await askNote(context, 'إكمال تدريب ${r['full_name']}', label: 'الدرجة من 100');
    if (s == null || !mounted) return;
    final score = int.tryParse(s);
    await runApi(context, () => ApiClient.instance.post('/hr/training/records/${r['id']}/complete', {'score': score}));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/hr/training/courses',
      builder: (context, data, reload) {
        final list = (data as List).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ElevatedButton.icon(onPressed: _newCourse, icon: const Icon(Icons.add), label: const Text('دورة جديدة')),
              ),
              if (list.isEmpty) const EmptyState(icon: Icons.school_outlined, title: 'لا توجد دورات تدريبية بعد'),
              ...list.map((c) {
                final records = (c['records'] as List).cast<Map>();
                final assigned = (asNum(c['assigned']) ?? 0).toInt();
                final completed = (asNum(c['completed']) ?? 0).toInt();
                return Card(
                  child: ExpansionTile(
                    title: Text('${c['title']}${c['mandatory_for'] != null ? ' (إلزامية: ${roleLabels[c['mandatory_for']] ?? c['mandatory_for']})' : ''}'),
                    subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('أكمل $completed من $assigned'),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: assigned == 0 ? 0 : completed / assigned),
                    ]),
                    childrenPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    children: [
                      if (c['description'] != null) Text('${c['description']}', style: const TextStyle(color: AppColors.muted)),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(onPressed: () => _assign(c), icon: const Icon(Icons.group_add), label: const Text('إسناد لموظفين')),
                      ),
                      ...records.map((r) => ListTile(
                            dense: true,
                            title: Text('${r['employee_code']} - ${r['full_name']}'),
                            subtitle: r['completed_at'] != null
                                ? Text('أُكملت ${formatDate(r['completed_at'])}${r['score'] != null ? ' | الدرجة ${r['score']}' : ''}')
                                : null,
                            trailing: r['status'] == 'completed'
                                ? StatusChip('مكتملة', statusTone('completed'))
                                : OutlinedButton(onPressed: () => _complete(r), child: const Text('تسجيل الإكمال')),
                          )),
                    ],
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}
