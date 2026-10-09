import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../shared/ui.dart';
import 'charts.dart';

const Map<String, String> _summaryLabels = {
  'total': 'كل الصفوف',
  'matched': 'طوبقت',
  'unmatched': 'بلا عقار',
  'duplicates': 'مكررة',
  'odd_amount': 'مبلغ غير معتاد',
  'invalid': 'غير صالحة',
  'skipped': 'متخطاة',
};

Color _summaryColor(String k) => switch (k) {
      'matched' => AppColors.good,
      'unmatched' => AppColors.warn,
      'duplicates' => AppColors.bad,
      'odd_amount' => AppColors.warn,
      'invalid' => AppColors.bad,
      'skipped' => AppColors.muted,
      _ => AppColors.muted,
    };

const Map<String, String> _matchedByLabels = {
  'account_no': 'رقم الحساب',
  'meter_serial': 'رقم العداد',
  'phone': 'الهاتف',
  'manual': 'ربط يدوي',
};

const Map<String, String> _importStatusLabels = {
  'staged': 'بانتظار المراجعة',
  'committed': 'معتمد',
  'discarded': 'ملغى',
};

Color _importStatusColor(String s) => switch (s) {
      'committed' => AppColors.good,
      'discarded' => AppColors.muted,
      _ => AppColors.warn,
    };

/// Colored chips for an import summary {total, matched, unmatched, duplicates, odd_amount, invalid, skipped}.
class _SummaryChips extends StatelessWidget {
  final Map summary;
  final bool hideZero;
  const _SummaryChips(this.summary, {this.hideZero = false});

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final k in _summaryLabels.keys)
        if (!hideZero || (asNum(summary[k]) ?? 0) != 0 || k == 'total')
          StatusChip('${_summaryLabels[k]}: ${formatNumber(asNum(summary[k]) ?? 0)}', _summaryColor(k)),
    ]);
  }
}

/// Single-line text prompt. Returns null when cancelled.
Future<String?> _askText(BuildContext context, String title, String label, {String initial = '', bool number = false}) async {
  final c = TextEditingController(text: initial);
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: number ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), errorText: error),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () {
              final t = c.text.trim();
              if (t.isEmpty || (number && num.tryParse(t.replaceAll(',', '')) == null)) {
                setD(() => error = number ? 'أدخل رقماً صحيحاً' : 'يرجى الكتابة');
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('تأكيد'),
          ),
        ],
      ),
    ),
  );
  final text = c.text.trim();
  Future.delayed(const Duration(milliseconds: 400), c.dispose);
  return ok == true ? text : null;
}

/// 'الفواتير السابقة' (finance): coverage of previous bills, upload of the directorate's file, review of each import.
class PrevBillsTab extends StatefulWidget {
  const PrevBillsTab({super.key});

  @override
  State<PrevBillsTab> createState() => _PrevBillsTabState();
}

class _PrevBillsTabState extends State<PrevBillsTab> {
  Map? _summary;
  List<Map> _imports = const [];
  String? _error;
  bool _loading = true;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _summary == null;
      _error = null;
    });
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/prev-bills/summary'),
        ApiClient.instance.get('/prev-bills/imports'),
      ]);
      if (!mounted) return;
      setState(() {
        _summary = res[0] is Map ? res[0] as Map : <String, dynamic>{};
        _imports = res[1] is List ? (res[1] as List).whereType<Map>().toList() : const [];
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _upload() async {
    final messenger = ScaffoldMessenger.of(context);
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx', 'csv'],
        withData: true,
      );
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('تعذر فتح اختيار الملفات')));
      return;
    }
    if (!mounted) return;
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('تعذر قراءة الملف')));
      return;
    }
    setState(() => _uploading = true);
    final r = await runApi(
      context,
      () => ApiClient.instance.post('/prev-bills/import', {
        'filename': file.name,
        'content_base64': base64Encode(bytes),
      }),
    );
    if (!mounted) return;
    setState(() => _uploading = false);
    if (r is! Map) return;
    final id = asNum(r['import_id'])?.toInt();
    _load();
    if (id == null) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PrevBillImportScreen(
        importId: id,
        columnsFound: ((r['columns_found'] as List?) ?? const []).map((e) => '$e').toList(),
      ),
    ));
    if (mounted) _load();
  }

  Future<void> _open(int id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PrevBillImportScreen(importId: id)));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _summary == null) {
      return EmptyState(
        icon: Icons.cloud_off,
        title: 'تعذر تحميل البيانات',
        message: _error,
        action: OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
      );
    }
    final s = _summary ?? const {};
    final coverage = asNum(s['coverage'])?.toDouble();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          AppCard(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('تغطية الفواتير السابقة', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                const Text('الفاتورة السابقة لكل منزل هي أساس حساب الزيادة (الخيار ب من صيغة الـ35%).',
                    style: TextStyle(fontSize: 12, color: AppColors.muted)),
                const SizedBox(height: 12),
                Row(children: [
                  Text(pctText(coverage, digits: 1),
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: (coverage ?? 0) >= 0.9 ? AppColors.good : AppColors.warn)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: (coverage ?? 0).clamp(0.0, 1.0),
                      minHeight: 10,
                      borderRadius: BorderRadius.circular(6),
                      color: (coverage ?? 0) >= 0.9 ? AppColors.good : AppColors.warn,
                      backgroundColor: AppColors.muted.withValues(alpha: 0.2),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  StatusChip('العقارات الفعالة: ${formatNumber(asNum(s['houses']))}', AppColors.muted),
                  StatusChip('لها فاتورة مؤكدة: ${formatNumber(asNum(s['confirmed']))}', AppColors.good),
                  StatusChip('بانتظار المراجعة: ${formatNumber(asNum(s['waiting']))}', AppColors.warn),
                  StatusChip('لا تطابق الميدان: ${formatNumber(asNum(s['mismatches']))}', AppColors.bad),
                ]),
              ]),
          ),
          AppCard(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('رفع ملف دائرة الماء', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text('ملف Excel (xlsx) أو CSV. الصف الأول عناوين الأعمدة. الأعمدة المقبولة:'),
                const SizedBox(height: 6),
                const Wrap(spacing: 6, runSpacing: 6, children: [
                  Chip(label: Text('رقم الحساب')),
                  Chip(label: Text('رقم العداد')),
                  Chip(label: Text('الهاتف')),
                  Chip(label: Text('المبلغ (إلزامي)')),
                  Chip(label: Text('المدة (بالأيام، الافتراضي 30)')),
                  Chip(label: Text('التاريخ')),
                  Chip(label: Text('الاستهلاك')),
                  Chip(label: Text('الاسم')),
                ]),
                const SizedBox(height: 6),
                const Text(
                  'يجب وجود رقم الحساب أو رقم العداد أو الهاتف لمطابقة العقارات. لا يُحفظ شيء قبل المراجعة والضغط على «اعتماد».',
                  style: TextStyle(fontSize: 12, color: AppColors.muted),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ElevatedButton.icon(
                    onPressed: _uploading ? null : _upload,
                    icon: _uploading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.upload_file),
                    label: Text(_uploading ? 'جارٍ الرفع والمطابقة...' : 'اختيار ملف ورفعه'),
                  ),
                ),
              ]),
          ),
          const SectionTitle('الملفات السابقة'),
          if (_imports.isEmpty) const EmptyState(icon: Icons.upload_file, title: 'لم يُرفع أي ملف بعد', message: 'ارفع ملف دائرة الماء أعلاه لبدء المطابقة'),
          ..._imports.map((i) {
            final status = '${i['status']}';
            final summary = i['summary'] is Map ? i['summary'] as Map : const {};
            return AppCard(
                padding: const EdgeInsets.all(Gap.md),
                onTap: () {
                  final id = asNum(i['id'])?.toInt();
                  if (id != null) _open(id);
                },
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.description_outlined),
                      const SizedBox(width: 8),
                      Expanded(child: Text('${i['filename']}', style: const TextStyle(fontWeight: FontWeight.bold))),
                      StatusChip(_importStatusLabels[status] ?? status, _importStatusColor(status)),
                    ]),
                    Text('${formatDate(i['uploaded_at'])} ${formatTime(i['uploaded_at'])} | ${i['uploaded_by'] ?? ''}',
                        style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                    const SizedBox(height: 6),
                    _SummaryChips(summary, hideZero: true),
                  ]),
            );
          }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Review of one staged import: problems / matched / all rows, per-row fixes, commit or discard.
class PrevBillImportScreen extends StatefulWidget {
  final int importId;
  final List<String>? columnsFound;
  const PrevBillImportScreen({super.key, required this.importId, this.columnsFound});

  @override
  State<PrevBillImportScreen> createState() => _PrevBillImportScreenState();
}

class _PrevBillImportScreenState extends State<PrevBillImportScreen> {
  String _show = 'problems';
  Map? _data;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  String get _base => '/prev-bills/imports/${widget.importId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final d = await ApiClient.instance.get('$_base?show=$_show');
      if (mounted) setState(() => _data = d is Map ? d : <String, dynamic>{});
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _fixRow(Map row, Map<String, dynamic> body, String success) async {
    final index = asNum(row['index'])?.toInt();
    if (index == null) return;
    setState(() => _busy = true);
    await runApi(context, () => ApiClient.instance.post('$_base/rows/$index', body), success: success);
    if (!mounted) return;
    setState(() => _busy = false);
    _load();
  }

  Future<void> _link(Map row) async {
    final code = await _askText(context, 'ربط الصف بعقار', 'رمز العقار', initial: '${row['property_code'] ?? ''}');
    if (code == null || !mounted) return;
    await _fixRow(row, {'property_code': code}, 'تم الربط');
  }

  Future<void> _fixAmount(Map row) async {
    final current = asNum(row['amount']);
    final t = await _askText(context, 'تصحيح المبلغ', 'المبلغ (د.ع)',
        initial: current == null ? '' : current.toString(), number: true);
    if (t == null || !mounted) return;
    final v = num.tryParse(t.replaceAll(',', ''));
    if (v == null) return;
    await _fixRow(row, {'amount': v}, 'تم تصحيح المبلغ');
  }

  Future<void> _commit() async {
    final ok = await confirm(context, 'اعتماد الملف',
        'ستُحفظ الصفوف المطابقة كفواتير سابقة. المبالغ غير المعتادة تذهب للمراجعة. لا يمكن التراجع عن الاعتماد.');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await ApiClient.instance.post('$_base/commit');
      if (!mounted) return;
      final m = r is Map ? r : const {};
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تم الاعتماد'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('حُفظت: ${formatNumber(asNum(m['saved']))} فاتورة'),
            Text('منها للمراجعة (مبلغ غير معتاد): ${formatNumber(asNum(m['to_review']))}'),
            Text('لم تُحفظ (بلا عقار / متخطاة / غير صالحة): ${formatNumber(asNum(m['left_out']))}'),
          ]),
          actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('حسناً'))],
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('لا يمكن الاعتماد بعد'),
            content: Text('${e.message}\n\nاعرض «المشاكل»، ثم تخطَّ أحد الصفين المكررين أو اربطه بالعقار الصحيح.'),
            actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('حسناً'))],
          ),
        );
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.bad));
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _load();
  }

  Future<void> _discard() async {
    final ok = await confirm(context, 'إلغاء الملف', 'سيُلغى هذا الملف ولن يُحفظ منه شيء.');
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    await runApi(context, () => ApiClient.instance.post('$_base/discard'), success: 'أُلغي الملف');
    if (!mounted) return;
    setState(() => _busy = false);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final status = '${d?['status'] ?? ''}';
    final staged = status == 'staged';
    return Scaffold(
      appBar: portalAppBar(
        title: d == null ? 'مراجعة الملف' : '${d['filename']}',
        color: AppColors.finance,
        actions: [IconButton(tooltip: 'تحديث', onPressed: _load, icon: const Icon(Icons.refresh))],
      ),
      bottomNavigationBar: staged
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _commit,
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.good, foregroundColor: Colors.white),
                      icon: const Icon(Icons.check_circle),
                      label: const Text('اعتماد'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _discard,
                    style: OutlinedButton.styleFrom(foregroundColor: AppColors.bad),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('إلغاء الملف'),
                  ),
                ]),
              ),
            )
          : null,
      body: _body(d, status, staged),
    );
  }

  Widget _body(Map? d, String status, bool staged) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && d == null) {
      return EmptyState(
        icon: Icons.cloud_off,
        title: 'تعذر تحميل البيانات',
        message: _error,
        action: OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
      );
    }
    final data = d ?? const {};
    final summary = data['summary'] is Map ? data['summary'] as Map : const {};
    final rows = ((data['rows'] as List?) ?? const []).whereType<Map>().toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          if (widget.columnsFound != null && widget.columnsFound!.isNotEmpty)
            NoticeBanner(
              icon: Icons.view_column,
              title: 'الأعمدة التي تعرّف عليها النظام',
              message: widget.columnsFound!.map((c) => _columnLabels[c] ?? c).join('، '),
            ),
          AppCard(
            padding: const EdgeInsets.all(Gap.md),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Expanded(child: Text('ملخص الملف', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
                  StatusChip(_importStatusLabels[status] ?? status, _importStatusColor(status)),
                ]),
                const SizedBox(height: 8),
                _SummaryChips(summary),
                if (!staged) ...[
                  const SizedBox(height: 8),
                  const Text('هذا الملف لم يعد قابلاً للتعديل.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                ],
              ]),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'problems', label: Text('المشاكل'), icon: Icon(Icons.error_outline)),
              ButtonSegment(value: 'matched', label: Text('المطابقة'), icon: Icon(Icons.check)),
              ButtonSegment(value: 'all', label: Text('الكل'), icon: Icon(Icons.list)),
            ],
            selected: {_show},
            onSelectionChanged: (s) {
              setState(() => _show = s.first);
              _load();
            },
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            EmptyState(
              icon: _show == 'problems' ? Icons.task_alt : Icons.table_rows_outlined,
              title: _show == 'problems' ? 'لا مشاكل في هذا الملف' : 'لا صفوف في هذا العرض',
            ),
          ...rows.map((r) => _rowCard(r, staged)),
          if (rows.length >= 500)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('تُعرض أول 500 صف فقط.', style: TextStyle(color: AppColors.muted, fontSize: 12)),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static const Map<String, String> _columnLabels = {
    'account_no': 'رقم الحساب',
    'meter_serial': 'رقم العداد',
    'phone': 'الهاتف',
    'name': 'الاسم',
    'amount': 'المبلغ',
    'period_days': 'المدة',
    'bill_date': 'التاريخ',
    'consumption': 'الاستهلاك',
  };

  Widget _rowCard(Map r, bool staged) {
    final skip = r['skip'] == true;
    final issue = r['issue'];
    final matched = r['property_id'] != null;
    final odd = r['odd'] == true;
    final ids = [
      if (r['account_no'] != null) 'حساب ${r['account_no']}',
      if (r['meter_serial'] != null) 'عداد ${r['meter_serial']}',
      if (r['phone'] != null) '${r['phone']}',
    ];
    return AppCard(
      accent: skip ? AppColors.faint : (issue != null ? AppColors.bad : (!matched || odd ? AppColors.warn : null)),
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('سطر ${r['line']}', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${r['name'] ?? '-'}',
                  style: TextStyle(fontWeight: FontWeight.bold, decoration: skip ? TextDecoration.lineThrough : null)),
            ),
            Text(asNum(r['amount']) == null ? 'بلا مبلغ' : formatIqd(asNum(r['amount'])),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, fontFeatures: [FontFeature.tabularFigures()])),
          ]),
          if (ids.isNotEmpty) Text(ids.join(' | '), style: const TextStyle(fontSize: 12)),
          Text('المدة ${r['period_days'] ?? 30} يوماً${r['bill_date'] != null ? ' | ${r['bill_date']}' : ''}',
              style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (matched)
              StatusChip('العقار ${r['property_code']} (${_matchedByLabels['${r['matched_by']}'] ?? r['matched_by']})',
                  AppColors.good)
            else
              StatusChip('بلا عقار', AppColors.warn),
            if (issue == 'duplicate') StatusChip('عقار مكرر في الملف', AppColors.bad),
            if (issue == 'invalid') StatusChip('مبلغ غير صالح', AppColors.bad),
            if (odd) StatusChip('مبلغ غير معتاد', AppColors.warn),
            if (skip) StatusChip('متخطى', AppColors.muted),
          ]),
          if (staged) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 4, children: [
              TextButton.icon(
                onPressed: _busy ? null : () => _link(r),
                icon: const Icon(Icons.link, size: 18),
                label: Text(matched ? 'تغيير العقار' : 'ربط بعقار'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : () => _fixAmount(r),
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('تصحيح المبلغ'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : () => _fixRow(r, {'skip': !skip}, skip ? 'أُعيد الصف' : 'تم تخطي الصف'),
                icon: Icon(skip ? Icons.undo : Icons.block, size: 18),
                label: Text(skip ? 'إلغاء التخطي' : 'تخطٍّ'),
              ),
            ]),
          ],
        ]),
    );
  }
}
