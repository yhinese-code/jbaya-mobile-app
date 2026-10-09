import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/location_service.dart';
import '../../core/photo_service.dart';
import '../../core/theme.dart';
import '../shared/ui.dart';

/// "خدماتي": employee self-service (attendance with selfie, leave, payslips, expenses, my file).
class SelfServiceScreen extends StatelessWidget {
  const SelfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: portalAppBar(
          title: 'خدماتي',
          color: AppColors.selfService,
          bottom: portalTabBar(const [
            Tab(icon: Icon(Icons.fingerprint), text: 'الحضور'),
            Tab(icon: Icon(Icons.beach_access), text: 'الإجازات'),
            Tab(icon: Icon(Icons.payments), text: 'رواتبي'),
            Tab(icon: Icon(Icons.receipt), text: 'المصروفات'),
            Tab(icon: Icon(Icons.badge), text: 'ملفي'),
          ]),
        ),
        body: const TabBarView(children: [_AttendanceTab(), _LeaveTab(), _PayslipsTab(), _ExpensesTab(), _MyFileTab()]),
      ),
    );
  }
}

// ---------------------------------------------------------------- attendance

class _AttendanceTab extends StatefulWidget {
  const _AttendanceTab();

  @override
  State<_AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends State<_AttendanceTab> {
  final _view = GlobalKey<ApiViewState>();
  bool _busy = false;

  Future<void> _punch(bool checkIn) async {
    setState(() => _busy = true);
    try {
      final selfie = await PhotoService.capture(front: true);
      if (selfie == null) return;
      GpsFix? gps;
      try {
        gps = await LocationService.current().timeout(const Duration(seconds: 20));
      } catch (_) {
        gps = null;
      }
      if (!mounted) return;
      final res = await runApi(
        context,
        () => ApiClient.instance.post('/me/attendance/${checkIn ? 'check-in' : 'check-out'}', {
          'lat': gps?.lat,
          'lng': gps?.lng,
          'gps_accuracy_m': gps?.accuracy,
          'is_mocked': gps?.isMocked ?? false,
          'selfie_base64': selfie.base64,
        }),
        success: checkIn ? 'تم تسجيل الحضور' : 'تم تسجيل الانصراف',
      );
      if (res != null && checkIn && mounted) {
        final lateMin = asNum(res['late_minutes']) ?? 0;
        final flags = (res['flags'] as List? ?? []);
        if (lateMin > 0 || flags.contains('outside_sector')) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: AppColors.warn,
            content: Text('${lateMin > 0 ? 'تأخير $lateMin دقيقة. ' : ''}${flags.contains('outside_sector') ? 'سُجّل الحضور خارج القاطع.' : ''}'),
          ));
        }
      }
      _view.currentState?.reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/me/attendance',
      builder: (context, data, reload) {
        final today = data['today'] as Map;
        final records = (data['records'] as List).cast<Map>();
        final checkedIn = today['checked_in_at'] != null;
        final checkedOut = today['checked_out_at'] != null;
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              AppCard(
                padding: const EdgeInsets.all(Gap.lg),
                child: Column(
                    children: [
                      Text('اليوم ${formatDate(today['date'])}', style: const TextStyle(fontSize: 16, color: AppColors.muted)),
                      const SizedBox(height: 8),
                      if (today['on_leave'] == true)
                        const StatusChip('في إجازة معتمدة', AppColors.info)
                      else if (today['working_day'] != true && !checkedIn)
                        const StatusChip('يوم عطلة', AppColors.muted),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _clock('الحضور', today['checked_in_at']),
                          _clock('الانصراف', today['checked_out_at']),
                          Column(children: [
                            const Text('بداية الدوام', style: TextStyle(color: AppColors.muted)),
                            Text('${data['shift_start']}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                          ]),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (!checkedIn && today['on_leave'] != true)
                        _bigButton('تسجيل الحضور (سيلفي + موقع)', Icons.login, AppColors.good, () => _punch(true))
                      else if (checkedIn && !checkedOut)
                        _bigButton('تسجيل الانصراف', Icons.logout, AppColors.warn, () => _punch(false))
                      else if (checkedOut)
                        const Text('✔ انتهى دوام اليوم', style: TextStyle(color: AppColors.good, fontWeight: FontWeight.bold)),
                    ],
                  ),
              ),
              const SectionTitle('سجل هذا الشهر'),
              if (records.isEmpty) const EmptyState(icon: Icons.fingerprint, title: 'لا توجد سجلات حضور هذا الشهر'),
              ...records.map((r) {
                final isLate = (asNum(r['late_minutes']) ?? 0) > 0;
                final worked = asNum(r['worked_minutes']);
                return Card(
                  child: ListTile(
                    leading: Icon(isLate ? Icons.schedule : Icons.check_circle, color: isLate ? AppColors.warn : AppColors.good),
                    title: Text(formatDate(r['work_date'])),
                    subtitle: Text('حضور ${formatTime(r['check_in_at'])} | انصراف ${formatTime(r['check_out_at'])}'
                        '${worked != null ? ' | ${(worked / 60).toStringAsFixed(1)} ساعة' : ''}'
                        '${isLate ? ' | تأخير ${r['late_minutes']} د' : ''}'),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _clock(String label, dynamic iso) {
    return Column(children: [
      Text(label, style: const TextStyle(color: AppColors.muted)),
      Text(iso == null ? '--:--' : formatTime(iso), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
    ]);
  }

  Widget _bigButton(String label, IconData icon, Color color, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: _busy ? null : onTap,
        icon: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Icon(icon),
        label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
      ),
    );
  }
}

// ---------------------------------------------------------------- leave

class _LeaveTab extends StatefulWidget {
  const _LeaveTab();

  @override
  State<_LeaveTab> createState() => _LeaveTabState();
}

class _LeaveTabState extends State<_LeaveTab> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _request(Map balances) async {
    String type = 'annual';
    DateTimeRange? range;
    final reason = TextEditingController();
    CapturedPhoto? attachment;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('طلب إجازة'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'نوع الإجازة', border: OutlineInputBorder()),
                  items: balances.entries.map((e) {
                    final b = e.value as Map;
                    final rem = b['remaining'];
                    return DropdownMenuItem(value: e.key as String, child: Text('${b['label']}${rem != null ? ' (المتبقي $rem)' : ''}'));
                  }).toList(),
                  onChanged: (v) => setD(() => type = v ?? 'annual'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.date_range),
                  label: Text(range == null ? 'اختيار الفترة' : '${apiDate(range!.start)} ← ${apiDate(range!.end)}'),
                  onPressed: () async {
                    final now = DateTime.now();
                    final r = await showDateRangePicker(
                      context: ctx,
                      firstDate: now.subtract(Duration(days: type == 'sick' ? 30 : 3)),
                      lastDate: now.add(const Duration(days: 365)),
                    );
                    if (r != null) setD(() => range = r);
                  },
                ),
                const SizedBox(height: 12),
                TextField(controller: reason, maxLines: 2, decoration: const InputDecoration(labelText: 'السبب', border: OutlineInputBorder())),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.attach_file),
                  label: Text(attachment == null ? 'إرفاق تقرير/مستند (اختياري)' : 'تم الإرفاق ✔'),
                  onPressed: () async {
                    final p = await PhotoService.capture();
                    if (p != null) setD(() => attachment = p);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: range == null ? null : () => Navigator.pop(ctx, true), child: const Text('إرسال الطلب')),
          ],
        ),
      ),
    );
    final reasonText = reason.text.trim();
    Future.delayed(const Duration(milliseconds: 400), reason.dispose);
    if (ok != true || range == null || !mounted) return;
    await runApi(
      context,
      () => ApiClient.instance.post('/me/leave', {
        'leave_type': type,
        'start_date': apiDate(range!.start),
        'end_date': apiDate(range!.end),
        'reason': reasonText.isEmpty ? null : reasonText,
        'attachment_base64': attachment?.base64,
      }),
      success: 'تم إرسال طلب الإجازة',
    );
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/me/leave',
      builder: (context, data, reload) {
        final balances = data['balances'] as Map;
        final requests = (data['requests'] as List).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: balances.values.map((b) {
                  final m = b as Map;
                  return Container(
                    width: 160,
                    padding: const EdgeInsets.all(Gap.md),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(Gap.radius),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${m['label']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text(m['remaining'] == null ? 'بدون حد' : 'المتبقي ${m['remaining']} من ${m['entitlement']}',
                            style: const TextStyle(fontSize: 12)),
                        Text('المستخدم ${m['used']}${(asNum(m['pending']) ?? 0) > 0 ? ' | قيد الطلب ${m['pending']}' : ''}',
                            style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                      ],
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: Gap.md),
              ElevatedButton.icon(
                onPressed: () => _request(balances),
                icon: const Icon(Icons.add),
                label: const Text('طلب إجازة جديد'),
              ),
              const SectionTitle('طلباتي'),
              if (requests.isEmpty) const EmptyState(icon: Icons.beach_access_outlined, title: 'لم تقدّم طلبات إجازة بعد'),
              ...requests.map((r) => Card(
                    child: ListTile(
                      title: Text('${r['label']} | ${r['days']} يوم'),
                      subtitle: Text('${r['start_date']} ← ${r['end_date']}'
                          '${r['decision_note'] != null ? '\n${r['decision_note']}' : ''}'),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          StatusChip(leaveStatusLabels[r['status']] ?? '${r['status']}', statusTone(r['status'] as String?)),
                          if ('${r['status']}'.startsWith('pending'))
                            InkWell(
                              onTap: () async {
                                await runApi(context, () => ApiClient.instance.post('/me/leave/${r['id']}/cancel'), success: 'تم الإلغاء');
                                reload();
                              },
                              child: const Padding(padding: EdgeInsets.only(top: 4), child: Text('إلغاء', style: TextStyle(color: AppColors.bad))),
                            ),
                        ],
                      ),
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- payslips

class _PayslipsTab extends StatelessWidget {
  const _PayslipsTab();

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/me/payslips',
      builder: (context, data, reload) {
        final list = (data as List).cast<Map>();
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.request_quote_outlined,
            title: 'لا توجد قسائم رواتب معتمدة بعد',
            message: 'تظهر القسيمة هنا بعد أن تعتمد المالية رواتب الشهر',
          );
        }
        return ListView(
          padding: const EdgeInsets.all(Gap.md),
          children: list
              .map((p) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.request_quote, color: AppColors.brand),
                      title: Text('راتب ${p['period']}'),
                      subtitle: Text('الإجمالي ${formatIqd(asNum(p['gross']))} | الاستقطاعات ${formatIqd(asNum(p['deductions']))}'),
                      trailing: Text(formatIqd(asNum(p['net'])),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.brand, fontFeatures: [FontFeature.tabularFigures()])),
                      onTap: () => showPayslip(context, '/me/payslips/${p['id']}'),
                    ),
                  ))
              .toList(),
        );
      },
    );
  }
}

/// Payslip detail dialog (used by the employee and by HR/finance).
Future<void> showPayslip(BuildContext context, String path, {Map? preloaded}) {
  Widget body(Map p) {
    final lines = (p['lines'] as List).cast<Map>();
    final stats = (p['stats'] as Map?) ?? {};
    Widget line(Map l) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${l['label']}'),
                    if ('${l['detail'] ?? ''}'.isNotEmpty) Text('${l['detail']}', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                  ],
                ),
              ),
              Text(formatIqd(asNum(l['amount'])),
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: l['kind'] == 'deduction' ? AppColors.bad : null,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        );
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (p['full_name'] != null) Text('${p['employee_code']} - ${p['full_name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('أيام العمل ${stats['working_days_month'] ?? '-'} | حضور ${stats['present_days'] ?? '-'} | غياب ${stats['absent_days'] ?? '-'} | '
              'إجازة ${stats['paid_leave_days'] ?? 0} | تأخير ${stats['late_days'] ?? 0}',
              style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          const Divider(),
          const Text('المستحقات', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.brand)),
          ...lines.where((l) => l['kind'] == 'earning').map(line),
          const Divider(),
          const Text('الاستقطاعات', style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.bad)),
          ...lines.where((l) => l['kind'] == 'deduction').map(line),
          const Divider(),
          Row(children: [
            const Expanded(child: Text('صافي الراتب', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            Text(formatIqd(asNum(p['net'])), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.brand)),
          ]),
        ],
      ),
    );
  }

  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('قسيمة راتب ${preloaded?['period'] ?? ''}'),
      content: SizedBox(
        width: 480,
        child: preloaded != null
            ? body(preloaded)
            : FutureBuilder<dynamic>(
                future: ApiClient.instance.get(path),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
                  }
                  if (snap.hasError) return NoticeBanner(tone: Tone.bad, title: 'تعذر تحميل القسيمة', message: '${snap.error}');
                  return body(snap.data as Map);
                },
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))],
    ),
  );
}

// ---------------------------------------------------------------- expenses

class _ExpensesTab extends StatefulWidget {
  const _ExpensesTab();

  @override
  State<_ExpensesTab> createState() => _ExpensesTabState();
}

class _ExpensesTabState extends State<_ExpensesTab> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _submit() async {
    String category = 'fuel';
    final amount = TextEditingController();
    final desc = TextEditingController();
    DateTime day = DateTime.now();
    CapturedPhoto? receipt;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('مطالبة مصروف'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'النوع', border: OutlineInputBorder()),
                  items: expenseCategoryLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (v) => setD(() => category = v ?? 'fuel'),
                ),
                const SizedBox(height: 10),
                TextField(controller: amount, keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'المبلغ (د.ع)', border: OutlineInputBorder())),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text('التاريخ: ${apiDate(day)}'),
                  onPressed: () async {
                    final d = await showDatePicker(context: ctx, initialDate: day,
                        firstDate: DateTime.now().subtract(const Duration(days: 60)), lastDate: DateTime.now());
                    if (d != null) setD(() => day = d);
                  },
                ),
                const SizedBox(height: 10),
                TextField(controller: desc, decoration: const InputDecoration(labelText: 'الوصف', border: OutlineInputBorder())),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.camera_alt),
                  label: Text(receipt == null ? 'تصوير الوصل (إلزامي)' : 'تم التصوير ✔'),
                  onPressed: () async {
                    final p = await PhotoService.capture();
                    if (p != null) setD(() => receipt = p);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('إرسال')),
          ],
        ),
      ),
    );
    final value = double.tryParse(amount.text.replaceAll(',', '').trim());
    final description = desc.text.trim();
    Future.delayed(const Duration(milliseconds: 400), () {
      amount.dispose();
      desc.dispose();
    });
    if (ok != true || !mounted) return;
    if (value == null || receipt == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى إدخال المبلغ وتصوير الوصل'), backgroundColor: AppColors.bad));
      return;
    }
    await runApi(
      context,
      () => ApiClient.instance.post('/me/expenses', {
        'category': category,
        'amount': value,
        'expense_date': apiDate(day),
        'description': description.isEmpty ? null : description,
        'receipt_base64': receipt!.base64,
      }),
      success: 'تم إرسال المطالبة',
    );
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/me/expenses',
      builder: (context, data, reload) {
        final list = (data as List).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              ElevatedButton.icon(onPressed: _submit, icon: const Icon(Icons.add), label: const Text('مطالبة جديدة')),
              const SizedBox(height: 8),
              if (list.isEmpty) const EmptyState(icon: Icons.receipt_long_outlined, title: 'لم تقدّم مطالبات مصاريف بعد'),
              ...list.map((x) => Card(
                    child: ListTile(
                      title: Text('${expenseCategoryLabels[x['category']] ?? x['category']} | ${formatIqd(asNum(x['amount']))}'),
                      subtitle: Text('${x['expense_date']}${x['description'] != null ? ' | ${x['description']}' : ''}'
                          '${x['decision_note'] != null ? '\n${x['decision_note']}' : ''}'),
                      trailing: StatusChip(expenseStatusLabels[x['status']] ?? '${x['status']}', statusTone(x['status'] as String?)),
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- my file

class _MyFileTab extends StatelessWidget {
  const _MyFileTab();

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/me/profile',
      builder: (context, p, reload) => ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text('${p['full_name']} (${p['employee_code']})', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${p['job_title'] ?? roleLabels[p['role']] ?? ''} | ${p['sector_name'] ?? ''}\n'
                  'المشرف: ${p['supervisor_name'] ?? '-'} | تاريخ المباشرة: ${p['hire_date'] ?? '-'}'),
              isThreeLine: true,
            ),
          ),
          AppCard(
            padding: const EdgeInsets.all(Gap.md),
            child: Wrap(spacing: 16, runSpacing: 8, children: [
                Text('الراتب الأساسي: ${formatIqd(asNum(p['base_salary']))}'),
                Text('بدل النقل: ${formatIqd(asNum(p['allowance_transport']))}'),
                Text('بدل الهاتف: ${formatIqd(asNum(p['allowance_phone']))}'),
                Text('بدل الخطورة: ${formatIqd(asNum(p['allowance_risk']))}'),
                Text('طريقة الاستلام: ${p['payment_method'] ?? '-'}'),
              ]),
          ),
          const SectionTitle('عهدتي'),
          ApiListSection(
            path: '/me/custody',
            empty: 'لا توجد عهدة مسلّمة إليك',
            itemBuilder: (c) => ListTile(
              leading: const Icon(Icons.inventory_2),
              title: Text('${custodyTypeLabels[c['item_type']] ?? c['item_type']} - ${c['description']}'),
              subtitle: Text('${c['serial_no'] ?? ''} | ${formatIqd(asNum(c['value_iqd']))}'),
              trailing: StatusChip(c['status'] == 'assigned' ? 'بعهدتي' : (c['status'] == 'returned' ? 'مُعادة' : 'مفقودة'),
                  statusTone(c['status'] == 'assigned' ? 'pending' : c['status'] as String?)),
            ),
          ),
          const SectionTitle('التدريب'),
          ApiListSection(
            path: '/me/training',
            empty: 'لا توجد دورات مطلوبة منك حالياً',
            itemBuilder: (t) => ListTile(
              leading: Icon(t['status'] == 'completed' ? Icons.verified : Icons.school, color: t['status'] == 'completed' ? AppColors.good : AppColors.warn),
              title: Text('${t['title']}'),
              subtitle: Text(t['status'] == 'completed' ? 'مكتملة${t['score'] != null ? ' | الدرجة ${t['score']}' : ''}' : 'مطلوب إكمالها'),
            ),
          ),
          const SectionTitle('تقييمي الشهري'),
          ApiListSection(
            path: '/me/appraisals',
            empty: 'لا يوجد تقييم بعد؛ يظهر بعد أن تحتسبه الموارد البشرية',
            itemBuilder: (a) => ListTile(
              leading: CircleAvatar(child: Text('${(asNum(a['final_score']) ?? 0).round()}')),
              title: Text('${a['period']} | ${a['recommendation']}'),
              subtitle: Text('تقييم المشرف: ${a['supervisor_rating'] ?? '-'} / 5${a['supervisor_note'] != null ? ' | ${a['supervisor_note']}' : ''}'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small non-scrolling list loaded from the API (for use inside another ListView).
class ApiListSection extends StatelessWidget {
  final String path;
  final String empty;
  final Widget Function(Map item) itemBuilder;
  const ApiListSection({super.key, required this.path, required this.empty, required this.itemBuilder});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<dynamic>(
      future: ApiClient.instance.get(path),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
        }
        if (snap.hasError) return NoticeBanner(tone: Tone.bad, title: 'تعذر التحميل', message: '${snap.error}');
        final list = (snap.data as List).cast<Map>();
        if (list.isEmpty) return Text(empty, style: const TextStyle(color: AppColors.muted));
        return Column(children: list.map((i) => Card(child: itemBuilder(i))).toList());
      },
    );
  }
}

/// AppBar button that opens "خدماتي"; shows a dot when the employee has not checked in on a working day.
class SelfServiceButton extends StatefulWidget {
  const SelfServiceButton({super.key});

  @override
  State<SelfServiceButton> createState() => _SelfServiceButtonState();
}

class _SelfServiceButtonState extends State<SelfServiceButton> {
  bool _needsCheckIn = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await ApiClient.instance.get('/me/summary');
      if (mounted) setState(() => _needsCheckIn = s['working_day'] == true && s['checked_in'] != true);
    } on ApiException catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'خدماتي (الحضور، الإجازات، الراتب)',
      onPressed: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SelfServiceScreen()));
        _load();
      },
      icon: Badge(isLabelVisible: _needsCheckIn, smallSize: 10, child: const Icon(Icons.badge)),
    );
  }
}
