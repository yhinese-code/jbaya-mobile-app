import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/location_service.dart';
import 'widgets/otp_panel.dart';
import 'widgets/receipt_card.dart';

/// Collection for one property (first visit or periodic):
/// reading/estimate -> SERVER computes the amount -> citizen gets the exact amount + code on WhatsApp
/// -> collector types the code the citizen reads out -> receipt.
class CollectionScreen extends StatefulWidget {
  /// Property summary: id, property_code, citizen_name, address, meter_status, last_reading, never_paid, open_bill_id
  final Map<String, dynamic> property;

  const CollectionScreen({super.key, required this.property});

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  final _readingController = TextEditingController();
  late bool _useEstimate;
  bool _loading = false;
  String? _error;

  Map<String, dynamic>? _bill;
  bool _otpSent = false;
  int _resendAfter = 60;
  Map<String, dynamic>? _receipt;

  Map<String, dynamic> get p => widget.property;
  bool get _meterWorking => p['meter_status'] == 'working';
  bool get _firstVisit => p['never_paid'] == true;

  @override
  void initState() {
    super.initState();
    _useEstimate = !_meterWorking;
    final openBill = p['open_bill_id'];
    if (openBill != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadBill(openBill as int));
    }
  }

  @override
  void dispose() {
    _readingController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadBill(int id) => _run(() async {
        final res = await ApiClient.instance.get('/bills/$id');
        setState(() => _bill = Map<String, dynamic>.from(res as Map));
      });

  Future<void> _createBill() => _run(() async {
        double? reading;
        if (!_useEstimate) {
          reading = double.tryParse(_readingController.text.trim());
          if (reading == null) {
            throw Exception('يرجى إدخال قراءة العداد بشكل صحيح');
          }
        }
        final gps = await LocationService.current();
        final res = await ApiClient.instance.post('/bills', {
          'property_id': p['id'],
          'method': _useEstimate ? 'estimate' : 'reading',
          'current_reading': reading,
          'lat': gps.lat,
          'lng': gps.lng,
          'gps_accuracy_m': gps.accuracy,
          'is_mocked': gps.isMocked,
        });
        final bill = Map<String, dynamic>.from(res as Map);
        setState(() {
          _bill = bill;
          _otpSent = bill['otp'] != null;
          if (bill['otp'] != null) {
            _resendAfter = (asNum(bill['otp']['resend_after_seconds']) ?? 60).toInt();
          }
        });
      });

  Future<void> _sendOtp() => _run(() async {
        final res = await ApiClient.instance.post('/bills/${_bill!['id']}/send-otp');
        setState(() {
          _otpSent = true;
          _resendAfter = (asNum(res['resend_after_seconds']) ?? 60).toInt();
        });
      });

  Future<void> _verify(String code, bool useMaster, String? reason) async {
    final res = await ApiClient.instance.post('/bills/${_bill!['id']}/verify', {
      'code': code,
      'use_master_code': useMaster,
      'reason': reason,
    });
    setState(() => _receipt = Map<String, dynamic>.from(res as Map));
  }

  Future<int?> _resend() async {
    final res = await ApiClient.instance.post('/bills/${_bill!['id']}/send-otp');
    return asNum(res['resend_after_seconds'])?.toInt();
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('جباية ${p['property_code'] ?? ''}'),
        backgroundColor: const Color(0xFF004D40),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _propertyHeader(),
                const SizedBox(height: 12),
                if (_receipt != null)
                  ReceiptCard(receipt: _receipt!, onDone: () => Navigator.of(context).pop(true))
                else if (_bill == null)
                  _readingCard()
                else
                  _billCard(),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _propertyHeader() {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.home, color: Color(0xFF004D40)),
        title: Text('${p['citizen_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(
          '${p['address'] ?? ''}\n'
          '${meterStatusLabels[p['meter_status']] ?? ''}'
          '${p['last_reading'] != null ? ' | القراءة السابقة (مقفلة): ${formatNumber(asNum(p['last_reading']), decimals: 1)} م³' : ''}',
        ),
        isThreeLine: true,
      ),
    );
  }

  Widget _readingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('قراءة العداد', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
            const SizedBox(height: 8),
            if (_firstVisit)
              Container(
                padding: const EdgeInsets.all(10),
                color: Colors.amber.shade50,
                child: const Text(
                  'زيارة أولى: تُسجَّل القراءة الحالية كقراءة أساس، ويُستوفى مبلغ تقديري عن الفترة. '
                  'الفواتير القادمة تُحسب على الفرق بين القراءتين.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _useEstimate,
              onChanged: _loading ? null : (v) => setState(() => _useEstimate = v ?? false),
              title: const Text('العداد عاطل / غير مقروء / غير موجود (تقدير)'),
              subtitle: _meterWorking && _useEstimate
                  ? const Text('العداد مسجل كعامل: التقدير يحتاج موافقة المشرف', style: TextStyle(color: Colors.orange))
                  : null,
            ),
            if (!_useEstimate)
              TextField(
                controller: _readingController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'القراءة الحالية على العداد (م³)',
                  border: OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loading ? null : _createBill,
              icon: _loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.calculate),
              label: const Text('احتساب المبلغ وإرساله للمواطن'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF004D40),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'المبلغ يُحسب في الخادم ويُرسل للمواطن عبر واتساب مع تنبيه بعدم دفع أكثر منه.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _billCard() {
    final b = _bill!;
    final status = b['status'] as String;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              b['visit_type'] == 'first_visit' ? 'فاتورة الزيارة الأولى (تقديرية)' : 'فاتورة دورية',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF004D40)),
            ),
            const Divider(),
            if (b['previous_reading'] != null) _row('القراءة السابقة', '${formatNumber(asNum(b['previous_reading']), decimals: 1)} م³'),
            if (b['current_reading'] != null) _row('القراءة الحالية', '${formatNumber(asNum(b['current_reading']), decimals: 1)} م³'),
            if (b['consumption'] != null) _row('الاستهلاك', '${formatNumber(asNum(b['consumption']), decimals: 1)} م³'),
            _row('مدة الفترة', '${b['period_days']} يوم'),
            _row('طريقة الاحتساب', b['billing_method'] == 'reading' ? 'حسب القراءة' : 'تقديري'),
            _row('رسوم الاستهلاك', formatIqd(asNum(b['gov_amount']))),
            _row('أجور الجباية', formatIqd(asNum(b['company_fee']))),
            const SizedBox(height: 8),
            Text(
              'المبلغ المطلوب: ${formatIqd(asNum(b['total_amount']))}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.green),
            ),
            const SizedBox(height: 12),
            if (status == 'awaiting_otp' && _otpSent)
              OtpPanel(
                phoneMasked: (b['phone_masked'] ?? '').toString(),
                resendAfterSeconds: _resendAfter,
                verifyLabel: 'تأكيد الدفع وإصدار الوصل',
                onVerify: _verify,
                onResend: _resend,
              )
            else if (status == 'awaiting_otp')
              ElevatedButton(
                onPressed: _loading ? null : _sendOtp,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF004D40), foregroundColor: Colors.white),
                child: const Text('إرسال المبلغ والرمز إلى واتساب المواطن'),
              )
            else if (status == 'pending_approval')
              _statusBox(Colors.orange, 'بانتظار موافقة المشرف على التقدير. حدّث الحالة بعد الموافقة.')
            else if (status == 'blocked_review')
              _statusBox(Colors.red, 'القراءة الحالية أقل من السابقة. تم إيقاف الجباية وإحالة الفاتورة للمشرف.')
            else if (status == 'cancelled')
              _statusBox(Colors.grey, 'تم رفض الفاتورة${b['review_note'] != null ? ': ${b['review_note']}' : ''}'),
            if (status == 'pending_approval' || status == 'blocked_review')
              TextButton.icon(
                onPressed: _loading ? null : () => _loadBill(b['id'] as int),
                icon: const Icon(Icons.refresh),
                label: const Text('تحديث الحالة'),
              ),
            if (status == 'cancelled')
              TextButton(
                onPressed: () => setState(() => _bill = null),
                child: const Text('إصدار فاتورة جديدة'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label), Text(value, style: const TextStyle(fontWeight: FontWeight.bold))],
      ),
    );
  }

  Widget _statusBox(Color color, String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    );
  }
}
