import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/photo_service.dart';

/// Supervisor -> bank: deposit all reconciled cash with a slip photo. Finance verifies it against the bank statement.
class DepositsTab extends StatefulWidget {
  const DepositsTab({super.key});

  @override
  State<DepositsTab> createState() => _DepositsTabState();
}

class _DepositsTabState extends State<DepositsTab> {
  Map<String, dynamic>? _cash;
  List<Map<String, dynamic>> _deposits = [];
  final _amountController = TextEditingController();
  final _bankController = TextEditingController(text: 'مصرف الرافدين');
  final _slipController = TextEditingController();
  CapturedPhoto? _slip;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _bankController.dispose();
    _slipController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/supervisor/cash'),
        ApiClient.instance.get('/supervisor/deposits'),
      ]);
      if (!mounted) return;
      setState(() {
        _cash = Map<String, dynamic>.from(res[0] as Map);
        _deposits = (res[1] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _takeSlip() async {
    try {
      final p = await PhotoService.capture();
      if (p != null && mounted) setState(() => _slip = p);
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر فتح الكاميرا: $e');
    }
  }

  Future<void> _submit() async {
    final amount = double.tryParse(_amountController.text.replaceAll(',', '').trim());
    if (amount == null || amount <= 0 || _slipController.text.trim().length < 2 || _bankController.text.trim().length < 2) {
      setState(() => _error = 'يرجى إدخال مبلغ الإيداع واسم المصرف ورقم الوصل');
      return;
    }
    if (_slip == null) {
      setState(() => _error = 'يجب تصوير وصل الإيداع المصرفي');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.post('/supervisor/deposits', {
        'amount': amount,
        'bank_name': _bankController.text.trim(),
        'slip_number': _slipController.text.trim(),
        'slip_photo_base64': _slip!.base64,
      });
      if (!mounted) return;
      final diff = asNum(res['difference']) ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(diff == 0
            ? 'تم تسجيل الإيداع، بانتظار تدقيق المالية'
            : 'تم تسجيل الإيداع بفرق ${formatIqd(diff)} عن النقد المستلم، سيُراجَع من المالية'),
        backgroundColor: diff == 0 ? Colors.green : Colors.orange,
      ));
      setState(() {
        _amountController.clear();
        _slipController.clear();
        _slip = null;
      });
      _load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cash = _cash;
    final pendingResolutions = (asNum(cash?['reconciliations_pending_resolution']) ?? 0) > 0;
    final toDeposit = asNum(cash?['cash_to_deposit']) ?? 0;
    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  color: Colors.teal.shade50,
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet, color: Colors.teal, size: 36),
                    title: Text('النقد بحوزتك للإيداع: ${formatIqd(toDeposit)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                    subtitle: Text('من ${cash?['reconciliations_ready'] ?? 0} مطابقة'
                        '${pendingResolutions ? ' | ${cash?['reconciliations_pending_resolution']} فرق بانتظار المعالجة' : ''}'),
                  ),
                ),
                if (pendingResolutions)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('عالج فروقات المطابقة أولاً (تبويب المطابقة النقدية) قبل الإيداع',
                        style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                  ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('تسجيل إيداع مصرفي', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _amountController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'المبلغ المكتوب في وصل المصرف (د.ع)', border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 10),
                        TextField(controller: _bankController, decoration: const InputDecoration(labelText: 'المصرف', border: OutlineInputBorder())),
                        const SizedBox(height: 10),
                        TextField(controller: _slipController, decoration: const InputDecoration(labelText: 'رقم وصل الإيداع', border: OutlineInputBorder())),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _takeSlip,
                          icon: const Icon(Icons.camera_alt),
                          label: Text(_slip == null ? 'تصوير وصل الإيداع (إلزامي)' : 'إعادة التصوير'),
                        ),
                        if (_slip != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(_slip!.bytes, height: 160, fit: BoxFit.cover),
                            ),
                          ),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                        ],
                        const SizedBox(height: 14),
                        ElevatedButton(
                          onPressed: (_loading || pendingResolutions || toDeposit <= 0) ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF004D40),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          child: const Text('تسجيل الإيداع'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('الإيداعات السابقة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ..._deposits.map((d) {
                  final status = d['status'];
                  final color = status == 'verified' ? Colors.green : (status == 'rejected' ? Colors.red : Colors.orange);
                  final label = status == 'verified' ? 'مُدقَّق' : (status == 'rejected' ? 'مرفوض' : 'بانتظار المالية');
                  return Card(
                    child: ListTile(
                      leading: Icon(Icons.account_balance, color: color),
                      title: Text('${formatIqd(asNum(d['amount']))} - ${d['bank_name']}'),
                      subtitle: Text('وصل ${d['slip_number']} | $label'
                          '${(asNum(d['difference']) ?? 0) != 0 ? ' | فرق ${formatIqd(asNum(d['difference']))}' : ''}'
                          '${d['finance_note'] != null ? '\n${d['finance_note']}' : ''}'),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
