import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/format.dart';
import '../../../core/photo_service.dart';
import '../../shared/ui.dart';

const _prevStatusLabels = {
  'confirmed': 'مؤكدة',
  'pending_review': 'بانتظار مراجعة المشرف',
  'mismatch': 'بانتظار مراجعة المشرف (لا تطابق)',
  'recorded': 'سُجّل: لا توجد فاتورة سابقة',
};

Color _prevStatusColor(String? s) => s == 'confirmed' ? const Color(0xFF2E7D32) : const Color(0xFFEF6C00);

/// Arabic-Indic digits and thousands separators -> a plain number.
double? _parseAmount(String text) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final ch in text.trim().split('')) {
    final i = arabic.indexOf(ch);
    if (i >= 0) {
      b.write(i);
    } else if (ch == '٫') {
      b.write('.');
    } else if (ch != ',' && ch != '،' && ch != ' ') {
      b.write(ch);
    }
  }
  return double.tryParse(b.toString());
}

/// The house's previous bill (from before the company), checked at the door.
/// Optional and non-blocking: collection works whether or not this is done.
class PrevBillCard extends StatefulWidget {
  final int propertyId;
  const PrevBillCard({super.key, required this.propertyId});

  @override
  State<PrevBillCard> createState() => PrevBillCardState();
}

class PrevBillCardState extends State<PrevBillCard> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  String? _result; // status returned by the last action

  String get _path => '/collector/properties/${widget.propertyId}/prev-bill';

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = _d == null;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.get(_path);
      if (mounted && res is Map) setState(() => _d = Map<String, dynamic>.from(res));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send(Map<String, dynamic> body, {String? success}) async {
    setState(() => _busy = true);
    final res = await runApi(context, () => ApiClient.instance.post(_path, body), success: success);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res is Map && res['status'] != null) _result = '${res['status']}';
    });
    if (res != null) await reload();
  }

  Future<void> _confirm() async {
    final ok = await confirm(context, 'مطابقة الفاتورة', 'هل المبلغ في الفاتورة الورقية مطابق للمبلغ المعروض؟');
    if (!ok || !mounted) return;
    await _send({'action': 'confirm'}, success: 'تم تأكيد الفاتورة السابقة');
  }

  Future<void> _none() async {
    final ok = await confirm(context, 'لا توجد فاتورة سابقة', 'هل تؤكد أن المواطن لا يملك فاتورة سابقة من دائرة الماء؟');
    if (!ok || !mounted) return;
    await _send({'action': 'none'}, success: 'تم التسجيل');
  }

  Future<void> _form({required bool mismatch}) async {
    final d = _d;
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PrevBillForm(mismatch: mismatch, accountNo: d?['account_no'] as String?),
    );
    if (body == null || !mounted) return;
    await _send(body, success: 'أُرسلت الفاتورة لمراجعة المشرف');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Card(child: ListTile(leading: Icon(Icons.history_edu), title: Text('الفاتورة السابقة'), subtitle: LinearProgressIndicator()));
    }
    if (_d == null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.history_edu, color: Colors.grey),
          title: const Text('الفاتورة السابقة'),
          subtitle: Text(_error ?? 'تعذر التحميل', style: const TextStyle(color: Colors.red, fontSize: 12)),
          trailing: IconButton(tooltip: 'إعادة المحاولة', icon: const Icon(Icons.refresh), onPressed: reload),
        ),
      );
    }
    final d = _d!;
    final pb = d['previous_bill'] is Map ? d['previous_bill'] as Map : null;
    final needsAction = d['needs_action'] == true;
    final status = pb == null ? _result : '${pb['status']}';
    final pending = status == 'pending_review' || status == 'mismatch';

    return Card(
      color: needsAction && _result == null ? Colors.amber.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.history_edu, color: Color(0xFF004D40)),
              const SizedBox(width: 8),
              const Expanded(child: Text('الفاتورة السابقة', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF004D40)))),
              if (status != null) StatusChip(_prevStatusLabels[status] ?? status, _prevStatusColor(status)),
            ]),
            const SizedBox(height: 6),
            if (pb != null) ...[
              Text('المبلغ: ${formatIqd(asNum(pb['amount']))}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              Text(
                '${pb['source'] == 'import' ? 'من ملف دائرة الماء' : 'إدخال ميداني'}'
                ' | المدة ${pb['period_days']} يوم'
                '${pb['bill_date'] != null ? ' | بتاريخ ${formatDate(pb['bill_date'])}' : ''}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (pb['field_amount'] != null)
                Text('المبلغ في الورقة: ${formatIqd(asNum(pb['field_amount']))}', style: const TextStyle(color: Colors.orange)),
            ] else
              const Text('لا توجد فاتورة سابقة مسجلة لهذا العقار. صوّر فاتورة المواطن القديمة إن وُجدت.',
                  style: TextStyle(fontSize: 13)),
            if (d['account_no'] != null)
              Text('رقم الحساب: ${d['account_no']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (pending)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('بانتظار مراجعة المشرف', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
              ),
            if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
            if (needsAction && !_busy && _result != 'recorded') ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 6, children: [
                if (pb != null) ...[
                  ElevatedButton.icon(
                    onPressed: _confirm,
                    icon: const Icon(Icons.check),
                    label: const Text('مطابقة للورقة'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _form(mismatch: true),
                    icon: const Icon(Icons.compare_arrows),
                    label: const Text('لا تطابق'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                  ),
                ] else ...[
                  ElevatedButton.icon(
                    onPressed: () => _form(mismatch: false),
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('إدخال الفاتورة'),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF004D40), foregroundColor: Colors.white),
                  ),
                  OutlinedButton(onPressed: _none, child: const Text('لا توجد فاتورة سابقة')),
                ],
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

/// Amount + photo of the paper bill (mismatch), or a full new entry when nothing was imported.
/// Pops the request body, or null when cancelled.
class _PrevBillForm extends StatefulWidget {
  final bool mismatch;
  final String? accountNo;
  const _PrevBillForm({required this.mismatch, this.accountNo});

  @override
  State<_PrevBillForm> createState() => _PrevBillFormState();
}

class _PrevBillFormState extends State<_PrevBillForm> {
  final _amount = TextEditingController();
  final _days = TextEditingController(text: '30');
  final _account = TextEditingController();
  final _note = TextEditingController();
  DateTime? _billDate;
  CapturedPhoto? _photo;
  bool _capturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _account.text = widget.accountNo ?? '';
  }

  @override
  void dispose() {
    _amount.dispose();
    _days.dispose();
    _account.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    setState(() => _capturing = true);
    try {
      final p = await PhotoService.capture();
      if (mounted && p != null) setState(() => _photo = p);
    } catch (_) {
      if (mounted) setState(() => _error = 'تعذر فتح الكاميرا');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _billDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (d != null && mounted) setState(() => _billDate = d);
  }

  void _submit() {
    final amount = _parseAmount(_amount.text);
    if (amount == null || amount < 0) {
      setState(() => _error = 'أدخل مبلغ الفاتورة الورقية بشكل صحيح');
      return;
    }
    if (_photo == null) {
      setState(() => _error = 'يجب تصوير الفاتورة الورقية');
      return;
    }
    final note = _note.text.trim();
    if (widget.mismatch) {
      Navigator.pop(context, <String, dynamic>{
        'action': 'mismatch',
        'amount': amount,
        'photo_base64': _photo!.base64,
        'note': note.isEmpty ? null : note,
      });
      return;
    }
    final days = _parseAmount(_days.text)?.round() ?? 30;
    if (days < 1 || days > 400) {
      setState(() => _error = 'مدة الفاتورة بالأيام غير صحيحة');
      return;
    }
    final account = _account.text.trim();
    Navigator.pop(context, <String, dynamic>{
      'action': 'new',
      'amount': amount,
      'period_days': days,
      'bill_date': _billDate == null ? null : apiDate(_billDate!),
      'photo_base64': _photo!.base64,
      'account_no': account.isEmpty ? null : account,
      'note': note.isEmpty ? null : note,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.mismatch ? 'الفاتورة الورقية لا تطابق' : 'إدخال الفاتورة السابقة'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: _capturing ? null : _takePhoto,
                icon: _capturing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.camera_alt),
                label: Text(_photo == null ? 'تصوير الفاتورة الورقية (إلزامي)' : 'إعادة التصوير'),
              ),
              if (_photo != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(_photo!.bytes, height: 160, fit: BoxFit.cover),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'المبلغ في الفاتورة الورقية (د.ع)', border: OutlineInputBorder()),
              ),
              if (!widget.mismatch) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _days,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'مدة الفاتورة (يوم)', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event),
                  label: Text(_billDate == null ? 'تاريخ الفاتورة (اختياري)' : 'تاريخ الفاتورة: ${apiDate(_billDate!)}'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _account,
                  decoration: const InputDecoration(labelText: 'رقم الحساب في دائرة الماء (اختياري)', border: OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)', border: OutlineInputBorder()),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        ElevatedButton(onPressed: _submit, child: const Text('إرسال للمراجعة')),
      ],
    );
  }
}
