import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../self_service/self_service_screen.dart' show showPayslip;
import '../shared/photo_dialog.dart';
import '../shared/ui.dart';

String currentPeriod() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}';
}

List<String> recentPeriods([int n = 12]) {
  final now = DateTime.now();
  return List.generate(n, (i) {
    final d = DateTime(now.year, now.month - i, 1);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}';
  });
}

// ================================================================ attendance (HR: everyone, supervisor: team)

class AttendanceDayTab extends StatefulWidget {
  const AttendanceDayTab({super.key});

  @override
  State<AttendanceDayTab> createState() => _AttendanceDayTabState();
}

class _AttendanceDayTabState extends State<AttendanceDayTab> {
  DateTime _day = DateTime.now();

  static const _labels = {'present': 'حاضر', 'late': 'متأخر', 'absent': 'غائب', 'leave': 'إجازة', 'weekend': 'عطلة'};

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.event),
              label: Text(apiDate(_day)),
              onPressed: () async {
                final d = await showDatePicker(context: context, initialDate: _day, firstDate: DateTime(2025), lastDate: DateTime.now());
                if (d != null) setState(() => _day = d);
              },
            ),
          ]),
        ),
        Expanded(
          child: ApiView(
            path: '/hr/attendance?day=${apiDate(_day)}',
            builder: (context, data, reload) {
              final rows = (data['rows'] as List).cast<Map>();
              final counts = <String, int>{};
              for (final r in rows) {
                counts[r['status'] as String] = (counts[r['status']] ?? 0) + 1;
              }
              return RefreshIndicator(
                onRefresh: reload,
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    Wrap(spacing: 8, children: counts.entries.map((e) => StatusChip('${_labels[e.key] ?? e.key}: ${e.value}',
                        statusColor(e.key == 'late' ? 'pending' : e.key))).toList()),
                    const SizedBox(height: 8),
                    ...rows.map((r) {
                      final flags = (r['flags'] as List? ?? []).cast<dynamic>();
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: statusColor(r['status'] == 'late' ? 'pending' : r['status'] as String?).withValues(alpha: 0.15),
                            child: Icon(Icons.person, color: statusColor(r['status'] == 'late' ? 'pending' : r['status'] as String?)),
                          ),
                          title: Text('${r['employee_code']} - ${r['full_name']}'),
                          subtitle: Text('${roleLabels[r['role']] ?? r['role']} | ${r['sector_name'] ?? ''}'
                              '${r['check_in_at'] != null ? '\nحضور ${formatTime(r['check_in_at'])} | انصراف ${formatTime(r['check_out_at'])}' : ''}'
                              '${(asNum(r['late_minutes']) ?? 0) > 0 ? ' | تأخير ${r['late_minutes']} د' : ''}'
                              '${flags.contains('outside_sector') ? ' | خارج القاطع' : ''}'),
                          isThreeLine: r['check_in_at'] != null,
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            if (r['has_selfie'] == true)
                              IconButton(
                                tooltip: 'صورة الحضور',
                                icon: const Icon(Icons.face),
                                onPressed: () => showEvidencePhoto(context, '/hr/attendance/${r['attendance_id']}/selfie', title: 'سيلفي الحضور'),
                              ),
                            StatusChip(_labels[r['status']] ?? '${r['status']}', statusColor(r['status'] == 'late' ? 'pending' : r['status'] as String?)),
                          ]),
                        ),
                      );
                    }),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ================================================================ leave approvals (supervisor step 1, HR step 2)

class LeaveApprovalsTab extends StatefulWidget {
  const LeaveApprovalsTab({super.key});

  @override
  State<LeaveApprovalsTab> createState() => _LeaveApprovalsTabState();
}

class _LeaveApprovalsTabState extends State<LeaveApprovalsTab> {
  bool _pendingOnly = true;
  final _view = GlobalKey<ApiViewState>();

  Future<void> _decide(Map r, String action) async {
    final note = await askNote(context, action == 'approve' ? 'الموافقة على الإجازة' : 'رفض الإجازة', required: action == 'reject');
    if (note == null || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/hr/leave/${r['id']}/decision', {'action': action, 'note': note.isEmpty ? null : note}),
        success: action == 'approve' ? 'تمت الموافقة' : 'تم الرفض');
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final isSupervisor = Session.instance.role == 'supervisor';
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SegmentedButton<bool>(
          segments: const [ButtonSegment(value: true, label: Text('بانتظار القرار')), ButtonSegment(value: false, label: Text('الكل'))],
          selected: {_pendingOnly},
          onSelectionChanged: (s) => setState(() => _pendingOnly = s.first),
        ),
      ),
      Expanded(
        child: ApiView(
          key: _view,
          path: '/hr/leave?status=${_pendingOnly ? 'pending' : 'all'}',
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            if (list.isEmpty) return const Center(child: Text('لا توجد طلبات'));
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: list.map((r) {
                  final canAct = isSupervisor ? r['status'] == 'pending_supervisor' : '${r['status']}'.startsWith('pending');
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text('${r['employee_code']} - ${r['full_name']}', style: const TextStyle(fontWeight: FontWeight.bold))),
                          StatusChip(leaveStatusLabels[r['status']] ?? '${r['status']}', statusColor(r['status'] as String?)),
                        ]),
                        Text('${r['label']} | ${r['days']} يوم | ${r['start_date']} ← ${r['end_date']}'),
                        if (r['reason'] != null) Text('السبب: ${r['reason']}', style: const TextStyle(color: Colors.grey)),
                        if (r['decision_note'] != null) Text('ملاحظة: ${r['decision_note']}', style: const TextStyle(color: Colors.grey)),
                        Wrap(spacing: 8, children: [
                          if (r['has_attachment'] == true)
                            TextButton.icon(
                              onPressed: () => showEvidencePhoto(context, '/hr/leave/${r['id']}/attachment', title: 'مرفق الإجازة'),
                              icon: const Icon(Icons.attach_file),
                              label: const Text('المرفق'),
                            ),
                          if (canAct) ...[
                            ElevatedButton(
                              onPressed: () => _decide(r, 'approve'),
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                              child: Text(isSupervisor ? 'موافقة (تحويل للموارد البشرية)' : 'اعتماد'),
                            ),
                            OutlinedButton(
                              onPressed: () => _decide(r, 'reject'),
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                              child: const Text('رفض'),
                            ),
                          ],
                        ]),
                      ]),
                    ),
                  );
                }).toList(),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ================================================================ expenses (HR + finance)

class ExpenseApprovalsTab extends StatefulWidget {
  const ExpenseApprovalsTab({super.key});

  @override
  State<ExpenseApprovalsTab> createState() => _ExpenseApprovalsTabState();
}

class _ExpenseApprovalsTabState extends State<ExpenseApprovalsTab> {
  String _status = 'pending';
  final _view = GlobalKey<ApiViewState>();

  Future<void> _decide(Map x, String action) async {
    final note = await askNote(context, action == 'approve' ? 'الموافقة على المصروف' : 'رفض المصروف', required: action == 'reject');
    if (note == null || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/hr/expenses/${x['id']}/decision', {'action': action, 'note': note.isEmpty ? null : note}));
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'pending', label: Text('بانتظار الموافقة')),
            ButtonSegment(value: 'approved', label: Text('موافق عليها')),
            ButtonSegment(value: 'paid', label: Text('مصروفة')),
            ButtonSegment(value: 'all', label: Text('الكل')),
          ],
          selected: {_status},
          onSelectionChanged: (s) => setState(() => _status = s.first),
        ),
      ),
      Expanded(
        child: ApiView(
          key: _view,
          path: '/hr/expenses?status=$_status',
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            if (list.isEmpty) return const Center(child: Text('لا توجد مطالبات'));
            final total = list.fold<double>(0, (s, x) => s + ((asNum(x['amount']) ?? 0).toDouble()));
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  Text('${list.length} مطالبة | ${formatIqd(total)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ...list.map((x) => Card(
                        child: ListTile(
                          title: Text('${x['employee_code']} - ${x['full_name']} | ${expenseCategoryLabels[x['category']] ?? x['category']}'),
                          subtitle: Text('${formatIqd(asNum(x['amount']))} | ${x['expense_date']}${x['description'] != null ? ' | ${x['description']}' : ''}'),
                          trailing: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                            if (x['has_receipt'] == true)
                              IconButton(icon: const Icon(Icons.receipt), tooltip: 'الوصل',
                                  onPressed: () => showEvidencePhoto(context, '/hr/expenses/${x['id']}/receipt', title: 'وصل المصروف')),
                            if (x['status'] == 'pending') ...[
                              IconButton(icon: const Icon(Icons.check_circle, color: Colors.green), tooltip: 'موافقة', onPressed: () => _decide(x, 'approve')),
                              IconButton(icon: const Icon(Icons.cancel, color: Colors.red), tooltip: 'رفض', onPressed: () => _decide(x, 'reject')),
                            ] else
                              StatusChip(expenseStatusLabels[x['status']] ?? '${x['status']}', statusColor(x['status'] as String?)),
                          ]),
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

// ================================================================ payroll (HR computes, finance approves & pays)

class PayrollTab extends StatefulWidget {
  const PayrollTab({super.key});

  @override
  State<PayrollTab> createState() => _PayrollTabState();
}

class _PayrollTabState extends State<PayrollTab> {
  String _period = currentPeriod();
  final _runs = GlobalKey<ApiViewState>();
  final _detail = GlobalKey<ApiViewState>();
  bool get _isHr => const ['hr', 'admin'].contains(Session.instance.role);
  bool get _isFinance => const ['finance', 'admin'].contains(Session.instance.role);

  Future<void> _compute() async {
    await runApi(context, () => ApiClient.instance.post('/hr/payroll/runs', {'period': _period}), success: 'تم احتساب رواتب $_period');
    _runs.currentState?.reload();
    _detail.currentState?.reload();
  }

  Future<void> _action(String action) async {
    String? paidFrom;
    if (action == 'approve') {
      final ok = await confirm(context, 'اعتماد الرواتب', 'بعد الاعتماد لا يمكن إعادة الاحتساب، وتظهر القسائم للموظفين.');
      if (!ok || !mounted) return;
    } else {
      paidFrom = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('من أين تُصرف الرواتب؟'),
          children: [
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'cash'), child: const Text('نقداً من صندوق المالية')),
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, 'bank'), child: const Text('تحويل من المصرف')),
          ],
        ),
      );
      if (paidFrom == null || !mounted) return;
    }
    await runApi(context, () => ApiClient.instance.post('/hr/payroll/runs/$_period/action', {
          'action': action,
          if (paidFrom != null) 'paid_from': paidFrom,
        }));
    _runs.currentState?.reload();
    _detail.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final runs = SizedBox(
        width: c.maxWidth >= 900 ? 280 : double.infinity,
        height: c.maxWidth >= 900 ? double.infinity : 200,
        child: ApiView(
          key: _runs,
          path: '/hr/payroll/runs',
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            return ListView(
              padding: const EdgeInsets.all(8),
              children: [
                if (_isHr)
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(_period),
                        initialValue: _period,
                        isDense: true,
                        decoration: const InputDecoration(labelText: 'الشهر', border: OutlineInputBorder(), isDense: true),
                        items: {...recentPeriods(), _period}.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                        onChanged: (v) => setState(() => _period = v ?? _period),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ElevatedButton(onPressed: _compute, child: const Text('احتساب')),
                  ]),
                const SizedBox(height: 8),
                if (list.isEmpty) const Text('لا توجد رواتب محتسبة', style: TextStyle(color: Colors.grey)),
                ...list.map((r) {
                  final t = (r['totals'] as Map?) ?? {};
                  final label = r['status'] == 'draft' ? 'مسودة' : (r['status'] == 'approved' ? 'معتمدة' : 'مصروفة');
                  return Card(
                    color: r['period'] == _period ? Colors.purple.shade50 : null,
                    child: ListTile(
                      title: Text('${r['period']}'),
                      subtitle: Text('${t['employees'] ?? 0} موظف | الصافي ${formatIqd(asNum(t['net']))}'),
                      trailing: StatusChip(label, statusColor(r['status'] == 'draft' ? 'pending' : (r['status'] == 'paid' ? 'paid' : 'approved'))),
                      onTap: () => setState(() => _period = r['period'] as String),
                    ),
                  );
                }),
              ],
            );
          },
        ),
      );
      final detail = ApiView(
        key: _detail,
        path: '/hr/payroll/runs/$_period',
        builder: (context, data, reload) {
          final slips = (data['payslips'] as List).cast<Map>();
          final t = (data['totals'] as Map?) ?? {};
          final status = data['status'];
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('رواتب $_period', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                StatusChip(status == 'draft' ? 'مسودة' : (status == 'approved' ? 'معتمدة' : 'مصروفة'),
                    statusColor(status == 'draft' ? 'pending' : 'approved')),
                Chip(label: Text('الإجمالي ${formatIqd(asNum(t['gross']))}')),
                Chip(label: Text('الاستقطاعات ${formatIqd(asNum(t['deductions']))}')),
                Chip(label: Text('الصافي ${formatIqd(asNum(t['net']))}')),
                Chip(label: Text('العمولات ${formatIqd(asNum(t['commission']))}')),
                if (_isHr && status == 'draft') OutlinedButton.icon(onPressed: _compute, icon: const Icon(Icons.refresh), label: const Text('إعادة احتساب')),
                if (_isFinance && status == 'draft')
                  ElevatedButton(onPressed: () => _action('approve'), child: const Text('اعتماد (المالية)')),
                if (_isFinance && status == 'approved')
                  ElevatedButton(onPressed: () => _action('mark_paid'), child: const Text('تسجيل الصرف')),
              ]),
              if (_isHr && status == 'draft')
                const Padding(padding: EdgeInsets.only(top: 6), child: Text('المسودة تُعتمد من قسم المالية.', style: TextStyle(color: Colors.grey))),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('الموظف')),
                    DataColumn(label: Text('حضور/غياب')),
                    DataColumn(label: Text('الإجمالي'), numeric: true),
                    DataColumn(label: Text('الاستقطاعات'), numeric: true),
                    DataColumn(label: Text('الصافي'), numeric: true),
                    DataColumn(label: Text('')),
                  ],
                  rows: slips.map((p) {
                    final s = (p['stats'] as Map?) ?? {};
                    return DataRow(cells: [
                      DataCell(Text('${p['employee_code']} - ${p['full_name']}')),
                      DataCell(Text('${s['present_days']} / ${s['absent_days']}')),
                      DataCell(Text(formatIqd(asNum(p['gross'])))),
                      DataCell(Text(formatIqd(asNum(p['deductions'])), style: const TextStyle(color: Colors.red))),
                      DataCell(Text(formatIqd(asNum(p['net'])), style: const TextStyle(fontWeight: FontWeight.bold))),
                      DataCell(IconButton(icon: const Icon(Icons.visibility), onPressed: () => showPayslip(context, '', preloaded: {...p, 'period': _period}))),
                    ]);
                  }).toList(),
                ),
              ),
            ],
          );
        },
      );
      if (c.maxWidth >= 900) {
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [runs, const VerticalDivider(width: 1), Expanded(child: detail)]);
      }
      return Column(children: [runs, const Divider(height: 1), Expanded(child: detail)]);
    });
  }
}

// ================================================================ appraisals (HR runs, supervisor rates)

class AppraisalsTab extends StatefulWidget {
  const AppraisalsTab({super.key});

  @override
  State<AppraisalsTab> createState() => _AppraisalsTabState();
}

class _AppraisalsTabState extends State<AppraisalsTab> {
  String _period = currentPeriod();
  final _view = GlobalKey<ApiViewState>();

  Future<void> _rate(Map a) async {
    int rating = (a['supervisor_rating'] as int?) ?? 3;
    final note = TextEditingController(text: (a['supervisor_note'] as String?) ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('تقييم ${a['full_name']}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (i) => IconButton(
                    icon: Icon(i < rating ? Icons.star : Icons.star_border, color: Colors.amber, size: 32),
                    onPressed: () => setD(() => rating = i + 1),
                  )),
            ),
            TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'ملاحظة', border: OutlineInputBorder())),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ')),
          ],
        ),
      ),
    );
    final n = note.text.trim();
    Future.delayed(const Duration(milliseconds: 400), note.dispose);
    if (ok != true || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/hr/appraisals/${a['id']}/rate', {'rating': rating, 'note': n.isEmpty ? null : n}));
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final isHr = const ['hr', 'admin'].contains(Session.instance.role);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<String>(
              initialValue: _period,
              decoration: const InputDecoration(labelText: 'الشهر', border: OutlineInputBorder(), isDense: true),
              items: recentPeriods().map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
              onChanged: (v) => setState(() => _period = v ?? _period),
            ),
          ),
          const SizedBox(width: 8),
          if (isHr)
            ElevatedButton.icon(
              onPressed: () async {
                await runApi(context, () => ApiClient.instance.post('/hr/appraisals/run', {'period': _period}), success: 'تم احتساب التقييم');
                _view.currentState?.reload();
              },
              icon: const Icon(Icons.calculate),
              label: const Text('احتساب التقييم التلقائي'),
            ),
        ]),
      ),
      Expanded(
        child: ApiView(
          key: _view,
          path: '/hr/appraisals?period=$_period',
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            if (list.isEmpty) return Center(child: Text(isHr ? 'اضغط "احتساب التقييم التلقائي"' : 'لم تحتسب الموارد البشرية تقييم هذا الشهر بعد'));
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: list.map((a) {
                  final m = (a['metrics'] as Map?) ?? {};
                  final score = (asNum(a['final_score']) ?? 0).toDouble();
                  final color = score >= 85 ? Colors.green : (score >= 70 ? Colors.teal : (score >= 50 ? Colors.orange : Colors.red));
                  String pct(dynamic v) => '${(((asNum(v) ?? 0) * 100)).round()}%';
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(backgroundColor: color, child: Text('${score.round()}', style: const TextStyle(color: Colors.white))),
                      title: Text('${a['employee_code']} - ${a['full_name']} | ${a['recommendation']}'),
                      subtitle: Text(
                        '${a['role'] == 'collector' ? 'التحصيل ${pct(m['collection_ratio'])} من الهدف | ' : ''}'
                        'الحضور ${pct(m['attendance_rate'])} | الالتزام بالوقت ${pct(m['punctuality'])} | دقة النقد ${pct(m['cash_accuracy'])}\n'
                        'أحداث أمنية ${m['security_events'] ?? 0} | إنذارات ${m['warnings'] ?? 0} | '
                        'تقييم المشرف ${a['supervisor_rating'] ?? '-'}/5 | التلقائي ${(asNum(a['auto_score']) ?? 0).round()}',
                      ),
                      isThreeLine: true,
                      trailing: IconButton(icon: const Icon(Icons.star_rate, color: Colors.amber), tooltip: 'تقييم المشرف', onPressed: () => _rate(a)),
                    ),
                  );
                }).toList(),
              ),
            );
          },
        ),
      ),
    ]);
  }
}
