import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../shared/ui.dart';
import 'charts.dart';
import 'deposits_verification_tab.dart';

bool get canWriteFinance => const ['finance', 'admin'].contains(Session.instance.role);
const _notes = [50000, 25000, 10000, 5000, 1000, 500, 250];

const sourceLabels = {
  'receipt': 'وصل',
  'reconciliation': 'تسليم جابٍ لمشرف',
  'resolution': 'إغلاق فرق جابٍ',
  'handover': 'تسليم مشرف للمالية',
  'handover_resolution': 'إغلاق فرق مشرف',
  'transfer': 'صندوق / مصرف',
  'payroll': 'رواتب',
  'remittance': 'تسليم الأمانة',
  'journal': 'تصحيح يدوي',
  'deposit': 'إيداع قديم',
  'deposit_verified': 'إيداع قديم',
  'deposit_rejected': 'إيداع قديم',
};

/// Counts notes by denomination. Returns {'denominations': {...}, 'total': n} or null.
Future<Map<String, dynamic>?> countCashDialog(BuildContext context, String title) {
  return showDialog<Map<String, dynamic>>(context: context, builder: (_) => _CountDialog(title: title));
}

class _CountDialog extends StatefulWidget {
  final String title;
  const _CountDialog({required this.title});

  @override
  State<_CountDialog> createState() => _CountDialogState();
}

class _CountDialogState extends State<_CountDialog> {
  final Map<int, TextEditingController> _c = {for (final n in _notes) n: TextEditingController()};
  final _note = TextEditingController();

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  int _n(int note) => int.tryParse(_c[note]!.text.trim()) ?? 0;
  int get _total => _notes.fold(0, (s, n) => s + n * _n(n));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('عدّ النقد قبل أن ترى المبلغ المتوقع. أدخل عدد الأوراق من كل فئة:', style: TextStyle(color: AppColors.muted)),
            const SizedBox(height: 8),
            ..._notes.map((n) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    Expanded(flex: 3, child: Text('ورقة ${formatNumber(n)}', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]))),
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _c[n],
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: '0'),
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      flex: 4,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerEnd,
                        child: Text(formatIqd(n * _n(n)), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                      ),
                    ),
                  ]),
                )),
            const Divider(),
            Text('المجموع المعدود: ${formatIqd(_total)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            TextField(controller: _note, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        ElevatedButton(
          onPressed: _total <= 0
              ? null
              : () => Navigator.pop(context, {
                    'denominations': {for (final n in _notes) if (_n(n) > 0) '$n': _n(n)},
                    'total': _total,
                    'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
                  }),
          child: const Text('حفظ العدّ'),
        ),
      ],
    );
  }
}

// ================================================================ استلام النقد (supervisor -> finance at HQ)

class HandoverTab extends StatefulWidget {
  const HandoverTab({super.key});

  @override
  State<HandoverTab> createState() => _HandoverTabState();
}

class _HandoverTabState extends State<HandoverTab> {
  final _waiting = GlobalKey<ApiViewState>();
  final _history = GlobalKey<ApiViewState>();
  Map? _last;

  void _reload() {
    _waiting.currentState?.reload();
    _history.currentState?.reload();
  }

  Future<void> _receive(Map s) async {
    final count = await countCashDialog(context, 'استلام نقد المشرف ${s['full_name']}');
    if (count == null || !mounted) return;
    final res = await runApi(context, () => ApiClient.instance.post('/finance/handovers', {
          'supervisor_code': s['employee_code'],
          'denominations': count['denominations'],
          'note': count['note'],
        }));
    if (res != null && mounted) setState(() => _last = res as Map);
    _reload();
  }

  Future<void> _resolve(Map h) async {
    final diff = (asNum(h['difference']) ?? 0).toDouble();
    final options = <String, String>{
      if (diff < 0) 'supervisor_paid': 'دفع المشرف النقص الآن نقداً',
      if (diff < 0) 'salary_deduction': 'يُخصم من راتب المشرف',
      if (diff > 0) 'surplus_income': 'تُسجّل الزيادة إيراداً للشركة',
      'write_off': diff < 0 ? 'شطب النقص (خسارة)' : 'شطب الزيادة',
    };
    String action = options.keys.first;
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(diff < 0 ? 'نقص ${formatIqd(-diff)}' : 'زيادة ${formatIqd(diff)}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 8, runSpacing: 8, children: options.entries
                .map((e) => ChoiceChip(label: Text(e.value), selected: action == e.key, onSelected: (_) => setD(() => action = e.key)))
                .toList()),
            const SizedBox(height: 8),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'السبب (إلزامي)')),
            const SizedBox(height: 6),
            const Text('الشطب فوق الحد المسموح ينتظر موافقة المالك.', style: TextStyle(color: AppColors.muted, fontSize: 12)),
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
    if (n.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اكتب السبب')));
      return;
    }
    await runApi(context, () => ApiClient.instance.post('/finance/handovers/${h['id'] ?? h['handover_id']}/resolve', {'action': action, 'note': n}));
    if (mounted) setState(() => _last = null);
    _reload();
  }

  Widget _resultCard(Map r) {
    final diff = (asNum(r['difference']) ?? 0).toDouble();
    final color = diff == 0 ? AppColors.good : AppColors.bad;
    return AppCard(
      accent: color,
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('تم الاستلام من ${r['supervisor_name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('عددتَ: ${formatIqd(asNum(r['counted_cash']))} | المفروض: ${formatIqd(asNum(r['expected_cash']))}'),
          Text(diff == 0 ? 'مطابق تماماً' : (diff < 0 ? 'نقص ${formatIqd(-diff)}' : 'زيادة ${formatIqd(diff)}'),
              style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
          if ((asNum(r['left_with_supervisor']) ?? 0) > 0)
            Text('بقيت ${r['left_with_supervisor']} مطابقات لم يعالج المشرف فروقاتها بعد، فلم تُسلَّم.', style: const TextStyle(color: AppColors.warn)),
          if (r['resolution_status'] == 'pending' && canWriteFinance)
            TextButton.icon(onPressed: () => _resolve(r), icon: const Icon(Icons.gavel), label: const Text('قرر ماذا نفعل بالفرق')),
        ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(Gap.md),
      children: [
        const Text('المشرف يحضر إلى المقر ويسلّم النقد. عُدّه أولاً؛ النظام يكشف المبلغ المفروض بعد الحفظ فقط.',
            style: TextStyle(color: AppColors.muted)),
        if (_last != null) _resultCard(_last!),
        const SectionTitle('مشرفون لديهم نقد للتسليم'),
        ApiView(
          key: _waiting,
          path: '/finance/handovers/waiting',
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.payments_outlined,
                title: 'لا يوجد نقد بانتظار التسليم',
                message: 'يظهر هنا المشرفون الذين أغلقوا صناديق جباتهم ولم يسلّموا النقد بعد',
              );
            }
            return Column(
              children: list
                  .map((s) => AppCard(
                        padding: const EdgeInsets.all(Gap.md),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            CircleAvatar(
                              backgroundColor: AppColors.finance.withValues(alpha: 0.10),
                              child: const Icon(Icons.person, color: AppColors.finance),
                            ),
                            const SizedBox(width: Gap.md),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${s['employee_code']} - ${s['full_name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text('نقد ${s['reconciliations']} تسليم من الجباة (${s['collectors']}) | منذ ${formatDate(s['oldest'])}',
                                    style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                              ]),
                            ),
                          ]),
                          if ((asNum(s['unresolved']) ?? 0) > 0) ...[
                            const SizedBox(height: Gap.sm),
                            StatusChip('${s['unresolved']} فروقات لم يعالجها المشرف بعد', AppColors.warn),
                          ],
                          if (canWriteFinance) ...[
                            const SizedBox(height: Gap.sm),
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: ElevatedButton.icon(
                                  onPressed: () => _receive(s), icon: const Icon(Icons.payments), label: const Text('استلام وعدّ')),
                            ),
                          ],
                        ]),
                      ))
                  .toList(),
            );
          },
        ),
        const SectionTitle('سجل الاستلام'),
        ApiView(
          key: _history,
          path: '/finance/handovers',
          builder: (context, data, reload) {
            final list = (data as List).cast<Map>();
            if (list.isEmpty) {
              return const EmptyState(icon: Icons.history, title: 'لم يُستلم نقد من المشرفين بعد');
            }
            return Column(
              children: list.map((h) {
                final diff = (asNum(h['difference']) ?? 0).toDouble();
                final waiting = h['resolution_status'] == 'pending';
                final owner = h['resolution_status'] == 'pending_owner';
                return AppCard(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${h['supervisor_code']} - ${h['supervisor_name']} | ${formatIqd(asNum(h['counted_cash']))}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('${formatDate(h['created_at'])} ${formatTime(h['created_at'])} | استلم: ${h['received_by']}'
                        '${h['resolution_label'] != null ? ' | ${h['resolution_label']}' : ''}',
                        style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                    const SizedBox(height: Gap.sm),
                    Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      StatusChip(diff == 0 ? 'مطابق' : (diff < 0 ? 'نقص ${formatIqd(-diff)}' : 'زيادة ${formatIqd(diff)}'),
                          diff == 0 ? AppColors.good : AppColors.bad),
                      if (owner) const StatusChip('بانتظار المالك', AppColors.info),
                      if (waiting && canWriteFinance) OutlinedButton(onPressed: () => _resolve(h), child: const Text('قرار')),
                    ]),
                  ]),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

// ================================================================ الصندوق والمصرف

class CashBoxTab extends StatefulWidget {
  const CashBoxTab({super.key});

  @override
  State<CashBoxTab> createState() => _CashBoxTabState();
}

class _CashBoxTabState extends State<CashBoxTab> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _move(String direction, double available) async {
    final amount = TextEditingController(text: available > 0 ? available.floor().toString() : '');
    final ref = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(direction == 'to_bank' ? 'إيداع من الصندوق في المصرف' : 'سحب من المصرف إلى الصندوق'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('المتاح: ${formatIqd(available)}'),
          TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ')),
          TextField(controller: ref, decoration: const InputDecoration(labelText: 'رقم الوصل المصرفي (اختياري)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تسجيل')),
        ],
      ),
    );
    final body = {
      'direction': direction,
      'amount': double.tryParse(amount.text.replaceAll(',', '').trim()) ?? 0,
      'reference': ref.text.trim().isEmpty ? null : ref.text.trim(),
    };
    Future.delayed(const Duration(milliseconds: 400), () {
      amount.dispose();
      ref.dispose();
    });
    if (ok != true || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/finance/transfers', body), success: 'تم التسجيل');
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/finance/transfers',
      builder: (context, d, reload) {
        final box = (asNum(d['cash_box']) ?? 0).toDouble();
        final bank = (asNum(d['bank']) ?? 0).toDouble();
        final items = (d['items'] as List).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(label: 'صندوق المالية (نقد في المقر)', value: formatIqd(box), icon: Icons.point_of_sale, color: AppColors.brand),
                KpiCard(label: 'المصرف', value: formatIqd(bank), icon: Icons.account_balance, color: AppColors.brand),
              ]),
              if (canWriteFinance)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Wrap(spacing: 8, children: [
                    ElevatedButton.icon(onPressed: box > 0 ? () => _move('to_bank', box) : null, icon: const Icon(Icons.arrow_upward), label: const Text('إيداع في المصرف')),
                    OutlinedButton.icon(onPressed: bank > 0 ? () => _move('from_bank', bank) : null, icon: const Icon(Icons.arrow_downward), label: const Text('سحب إلى الصندوق')),
                  ]),
                ),
              const SectionTitle('الحركات'),
              if (items.isEmpty) const EmptyState(icon: Icons.swap_vert, title: 'لا توجد حركات بين الصندوق والمصرف بعد'),
              ...items.map((t) => Card(
                    child: ListTile(
                      leading: Icon(t['direction'] == 'to_bank' ? Icons.arrow_upward : Icons.arrow_downward,
                          color: t['direction'] == 'to_bank' ? AppColors.brand : AppColors.brand),
                      title: Text('${t['direction'] == 'to_bank' ? 'إيداع في المصرف' : 'سحب إلى الصندوق'}: ${formatIqd(asNum(t['amount']))}'),
                      subtitle: Text('${formatDate(t['created_at'])} | ${t['by']}${t['reference'] != null ? ' | ${t['reference']}' : ''}'),
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ أمانة دائرة الماء

class TrustTab extends StatefulWidget {
  const TrustTab({super.key});

  @override
  State<TrustTab> createState() => _TrustTabState();
}

class _TrustTabState extends State<TrustTab> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _handOver(Map d) async {
    final held = (asNum(d['held']) ?? 0).toDouble();
    final amount = TextEditingController(text: held > 0 ? held.floor().toString() : '');
    final ref = TextEditingController();
    final note = TextEditingController();
    String source = 'bank';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('تسليم أمانة دائرة الماء'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('الأمانة المحفوظة حالياً: ${formatIqd(held)}'),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'bank', label: Text('من المصرف')),
                  ButtonSegment(value: 'cash', label: Text('نقداً من الصندوق')),
                ],
                selected: {source},
                onSelectionChanged: (s) => setD(() => source = s.first),
              ),
              Text('في المصرف ${compactIqd((asNum(d['bank']) ?? 0).toDouble())} | في الصندوق ${compactIqd((asNum(d['cash_box']) ?? 0).toDouble())}',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ')),
              TextField(controller: ref, decoration: const InputDecoration(labelText: 'رقم الحوالة أو وصل الاستلام')),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تسجيل التسليم')),
          ],
        ),
      ),
    );
    final body = {
      'amount': double.tryParse(amount.text.replaceAll(',', '').trim()) ?? 0,
      'bank_ref': ref.text.trim(),
      'source': source,
      'note': note.text.trim().isEmpty ? null : note.text.trim(),
    };
    Future.delayed(const Duration(milliseconds: 400), () {
      amount.dispose();
      ref.dispose();
      note.dispose();
    });
    if (ok != true || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/finance/remittances', body), success: 'تم تسجيل التسليم');
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/finance/trust',
      builder: (context, d, reload) {
        final items = (d['items'] as List).cast<Map>();
        final held = (asNum(d['held']) ?? 0).toDouble();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              const NoticeBanner(
                icon: Icons.lock_outline,
                title: 'أمانة دائرة الماء ليست دخلاً للشركة',
                message: 'المبلغ الذي يدفعه المواطن عن الماء (بعد حصة الشركة المتفق عليها). '
                    'نحفظه نيابةً عن الدائرة ونسلّمه لها؛ هو ليس دخلاً للشركة وليس ديناً عليها.',
              ),
              const SizedBox(height: Gap.sm),
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(label: 'محفوظة لدينا الآن', value: formatIqd(held), icon: Icons.lock, color: held > 0 ? AppColors.warn : AppColors.good),
                KpiCard(label: 'حُصّلت هذا الشهر', value: formatIqd(asNum(d['collected_this_month'])), icon: Icons.download, color: AppColors.muted),
                KpiCard(label: 'سُلّمت هذا الشهر', value: formatIqd(asNum(d['handed_over_this_month'])), icon: Icons.upload, color: AppColors.brand),
                KpiCard(label: 'سُلّمت منذ البداية', value: formatIqd(asNum(d['handed_over_total'])), icon: Icons.history, color: AppColors.brand),
              ]),
              if (canWriteFinance)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: ElevatedButton.icon(onPressed: held > 0 ? () => _handOver(d) : null, icon: const Icon(Icons.send), label: const Text('تسليم للدائرة')),
                  ),
                ),
              const SectionTitle('سجل التسليم'),
              if (items.isEmpty) const EmptyState(icon: Icons.outbox_outlined, title: 'لم يُسلَّم شيء من الأمانة للدائرة بعد'),
              ...items.map((r) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.outbox, color: AppColors.brand),
                      title: Text('${formatIqd(asNum(r['amount']))} | ${r['bank_ref']}'),
                      subtitle: Text('${formatDate(r['remitted_at'])} | ${r['source'] == 'cash' ? 'نقداً من الصندوق' : 'من المصرف'} | ${r['created_by']}'
                          '${r['note'] != null ? ' | ${r['note']}' : ''}'),
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ الفروقات

class DifferencesTab extends StatefulWidget {
  const DifferencesTab({super.key});

  @override
  State<DifferencesTab> createState() => _DifferencesTabState();
}

class _DifferencesTabState extends State<DifferencesTab> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _closeField(Map r, String action) async {
    final note = await askNote(context, action == 'salary_deduction' ? 'خصم النقص من راتب الجابي' : 'شطب الفرق', required: true);
    if (note == null || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/finance/reconciliations/${r['id']}/close', {'action': action, 'note': note}));
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/finance/differences',
      builder: (context, data, reload) {
        final list = (data as List).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              const Text('فروقات نقدية تحتاج قراراً: فروقات الجباة التي أحالها المشرفون، وفروقات المشرفين عند العدّ في المقر. '
                  'الشطب فوق الحد المسموح ينتظر موافقة المالك.', style: TextStyle(color: AppColors.muted, fontSize: 12)),
              const SizedBox(height: 8),
              if (list.isEmpty) const EmptyState(icon: Icons.task_alt, title: 'لا توجد فروقات بانتظار القرار'),
              ...list.map((r) {
                final diff = (asNum(r['difference']) ?? 0).toDouble();
                final field = r['kind'] == 'field';
                final owner = r['waiting_for_owner'] == true;
                return AppCard(
                  accent: diff < 0 ? AppColors.bad : AppColors.warn,
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text('${field ? 'الجابي' : 'المشرف'} ${r['person_code']} - ${r['person_name']}',
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        StatusChip(diff < 0 ? 'نقص ${formatIqd(-diff)}' : 'زيادة ${formatIqd(diff)}', diff < 0 ? AppColors.bad : AppColors.warn),
                      ]),
                      Text('${field ? 'عند التسليم للمشرف' : 'عند العدّ في المقر'} | المفروض ${formatIqd(asNum(r['expected_cash']))} | '
                          'المعدود ${formatIqd(asNum(r['counted_cash']))} | ${formatDate(r['created_at'])}'),
                      if (r['note'] != null) Text('${r['note']}', style: const TextStyle(color: AppColors.muted)),
                      if (owner) const Padding(padding: EdgeInsets.only(top: 6), child: StatusChip('بانتظار موافقة المالك', AppColors.info)),
                      if (!owner && canWriteFinance) const SizedBox(height: Gap.sm),
                      if (!owner && canWriteFinance)
                        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
                          if (field && diff < 0) ElevatedButton(onPressed: () => _closeField(r, 'salary_deduction'), child: const Text('خصم من الراتب')),
                          if (field) OutlinedButton(onPressed: () => _closeField(r, 'write_off'), child: Text(diff < 0 ? 'شطب كخسارة' : 'تسجيل كإيراد')),
                          if (!field) const Text('افتح «استلام النقد» لاتخاذ القرار', style: TextStyle(color: AppColors.muted)),
                        ]),
                    ]),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ دفتر الحساب

class BookTab extends StatelessWidget {
  const BookTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(children: [
        TabBar(tabs: [Tab(text: 'الحسابات'), Tab(text: 'التصحيحات اليدوية')]),
        Expanded(child: TabBarView(children: [_BookAccounts(), _Corrections()])),
      ]),
    );
  }
}

class _BookAccounts extends StatelessWidget {
  const _BookAccounts();

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/finance/book',
      builder: (context, d, reload) {
        final groups = (d['groups'] as List).cast<Map>();
        final legacy = (asNum((d['cash'] as Map)['old_deposits_pending']) ?? 0) != 0;
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(Gap.md),
            children: [
              const Text('كل حساب يُظهر ما دخله وما خرج منه وما فيه الآن. الأرقام تُحسب تلقائياً من العمل الميداني؛ اضغط على حساب لرؤية تفاصيله.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12)),
              if (legacy)
                NoticeBanner(
                  tone: Tone.warn,
                  title: 'توجد إيداعات مصرفية قديمة من المشرفين بانتظار التدقيق',
                  action: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => Scaffold(
                              appBar: portalAppBar(title: 'إيداعات قديمة', color: AppColors.finance),
                              body: const DepositsVerificationTab()))),
                      child: const Text('تدقيق'),
                    ),
                  ),
                ),
              ...groups.map((g) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SectionTitle('${g['label']}'),
                    ...(g['accounts'] as List).cast<Map>().map((a) {
                      final bal = (asNum(a['balance']) ?? 0).toDouble();
                      return Card(
                        child: ListTile(
                          title: Text('${a['name']}'),
                          subtitle: Text('دخل ${formatIqd(asNum(a['in']))} | خرج ${formatIqd(asNum(a['out']))}'),
                          trailing: Text(formatIqd(bal), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: bal < 0 ? AppColors.bad : null)),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountPage(code: '${a['code']}', name: '${a['name']}'))),
                        ),
                      );
                    }),
                  ])),
            ],
          ),
        );
      },
    );
  }
}

class AccountPage extends StatefulWidget {
  final String code;
  final String name;
  const AccountPage({super.key, required this.code, required this.name});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  late DateTime _start;
  DateTime _end = DateTime.now();

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _start = DateTime(n.year, n.month, 1);
  }

  Future<void> _pick(bool start) async {
    final p = await showDatePicker(context: context, initialDate: start ? _start : _end, firstDate: DateTime(2025), lastDate: DateTime.now());
    if (p != null) setState(() => start ? _start = p : _end = p);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: portalAppBar(title: widget.name, color: AppColors.finance),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(Gap.md),
          child: Wrap(spacing: 8, children: [
            OutlinedButton(onPressed: () => _pick(true), child: Text('من ${apiDate(_start)}')),
            OutlinedButton(onPressed: () => _pick(false), child: Text('إلى ${apiDate(_end)}')),
          ]),
        ),
        Expanded(
          child: ApiView(
            path: '/finance/book/${widget.code}?start=${apiDate(_start)}&end=${apiDate(_end)}',
            builder: (context, d, reload) {
              final lines = (d['lines'] as List).cast<Map>();
              return ListView(
                padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                children: [
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    Chip(label: Text('كان فيه ${formatIqd(asNum(d['opening']))}')),
                    Chip(label: Text('دخل ${formatIqd(asNum(d['total_in']))}')),
                    Chip(label: Text('خرج ${formatIqd(asNum(d['total_out']))}')),
                    Chip(label: Text('فيه الآن ${formatIqd(asNum(d['closing']))}', style: const TextStyle(fontWeight: FontWeight.bold))),
                  ]),
                  if (d['truncated'] == true) const NoticeBanner(tone: Tone.warn, title: 'عُرضت أول 500 حركة؛ ضيّق الفترة.'),
                  if (lines.isEmpty) const EmptyState(title: 'لا حركات في هذه الفترة'),
                  ...lines.map((l) {
                    final i = (asNum(l['in']) ?? 0).toDouble();
                    final o = (asNum(l['out']) ?? 0).toDouble();
                    return Card(
                      child: ListTile(
                        dense: true,
                        leading: Icon(i > 0 ? Icons.add_circle : Icons.remove_circle, color: i > 0 ? AppColors.good : AppColors.bad),
                        title: Text('${l['memo'] ?? ''}${l['employee_name'] != null ? ' — ${l['employee_name']}' : ''}'),
                        subtitle: Text('${formatDate(l['at'])} ${formatTime(l['at'])} | ${sourceLabels[l['source']] ?? l['source']} ${l['ref']}'),
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text(i > 0 ? '+${formatNumber(i)}' : '-${formatNumber(o)}',
                              style: TextStyle(fontWeight: FontWeight.bold, color: i > 0 ? AppColors.good : AppColors.bad)),
                          Text('الرصيد ${formatNumber(asNum(l['balance']))}', style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                        ]),
                      ),
                    );
                  }),
                ],
              );
            },
          ),
        ),
      ]),
    );
  }
}

const _correctionKinds = {
  'bank_charge': 'عمولة مصرفية (تُخصم من المصرف)',
  'cash_expense': 'مصروف نقدي من الصندوق',
  'tax_paid': 'تسديد الضرائب والضمان المستقطعة',
  'opening_cash_box': 'رصيد افتتاحي للصندوق',
  'opening_bank': 'رصيد افتتاحي للمصرف',
};

class _Corrections extends StatefulWidget {
  const _Corrections();

  @override
  State<_Corrections> createState() => _CorrectionsState();
}

class _CorrectionsState extends State<_Corrections> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _new() async {
    String kind = 'bank_charge';
    final amount = TextEditingController();
    final memo = TextEditingController();
    DateTime day = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('تصحيح يدوي'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'نوع التصحيح'),
                items: _correctionKinds.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                onChanged: (v) => setD(() => kind = v ?? kind),
              ),
              TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ')),
              TextField(controller: memo, decoration: const InputDecoration(labelText: 'السبب / البيان')),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () async {
                  final p = await showDatePicker(context: ctx, initialDate: day, firstDate: DateTime(2025), lastDate: DateTime.now());
                  if (p != null) setD(() => day = p);
                },
                child: Text('التاريخ ${apiDate(day)}'),
              ),
              const SizedBox(height: 6),
              const Text('التصحيح الكبير ينتظر موافقة المالك قبل أن يظهر في الحسابات.', style: TextStyle(color: AppColors.muted, fontSize: 12)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تسجيل')),
          ],
        ),
      ),
    );
    final body = {
      'kind': kind,
      'amount': double.tryParse(amount.text.replaceAll(',', '').trim()) ?? 0,
      'memo': memo.text.trim(),
      'entry_date': apiDate(day),
    };
    Future.delayed(const Duration(milliseconds: 400), () {
      amount.dispose();
      memo.dispose();
    });
    if (ok != true || !mounted) return;
    final res = await runApi(context, () => ApiClient.instance.post('/finance/journal/simple', body));
    if (res != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res['status'] == 'pending_owner' ? 'أُرسل للمالك للموافقة' : 'تم التسجيل')));
    }
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/finance/journal',
      builder: (context, data, reload) {
        final list = (data as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(Gap.md),
          children: [
            if (canWriteFinance || Session.instance.role == 'owner')
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ElevatedButton.icon(onPressed: _new, icon: const Icon(Icons.add), label: const Text('تصحيح جديد')),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('للأشياء التي لا يراها النظام فقط: عمولات المصرف، مصاريف نقدية، تسديد الضرائب، الأرصدة الافتتاحية. '
                  'لا يُحذف تصحيح؛ يُلغى بتصحيح معاكس.', style: TextStyle(color: AppColors.muted, fontSize: 12)),
            ),
            if (list.isEmpty) const EmptyState(icon: Icons.edit_note, title: 'لا توجد تصحيحات يدوية'),
            ...list.map((e) {
              final lines = (e['lines'] as List).cast<Map>();
              final status = '${e['status']}';
              return Card(
                child: ListTile(
                  title: Text('${e['memo']}'),
                  subtitle: Text('${formatDate(e['posted_at'])} | ${e['created_by']}\n'
                      '${lines.map((l) => '${l['account_name']} ${(asNum(l['in']) ?? 0) > 0 ? '+${formatNumber(asNum(l['in']))}' : '-${formatNumber(asNum(l['out']))}'}').join(' | ')}'),
                  isThreeLine: true,
                  trailing: status == 'posted'
                      ? (canWriteFinance && !'${e['memo']}'.startsWith('عكس القيد')
                          ? TextButton(
                              onPressed: () async {
                                final ok = await confirm(context, 'إلغاء التصحيح', 'سيُسجَّل تصحيح معاكس بتاريخ اليوم.');
                                if (!ok || !context.mounted) return;
                                await runApi(context, () => ApiClient.instance.post('/finance/journal/${e['id']}/reverse'));
                                if (context.mounted) reload();
                              },
                              child: const Text('إلغاء'))
                          : null)
                      : StatusChip(status == 'pending_owner' ? 'بانتظار المالك' : 'رفضه المالك', status == 'pending_owner' ? AppColors.info : AppColors.bad),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
