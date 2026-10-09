import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/location_service.dart';
import '../../core/offline_queue.dart';
import '../../core/photo_service.dart';
import '../../core/theme.dart';
import 'widgets/otp_panel.dart';
import 'widgets/prev_bill_sheet.dart';
import 'widgets/receipt_card.dart';
import 'widgets/step_indicator.dart';

/// Collection for one property (first visit or periodic):
/// reading/estimate -> SERVER computes the amount -> citizen gets the exact amount + code on WhatsApp
/// -> collector types the code the citizen reads out -> receipt.
/// Offline (mobile): the reading (photo + GPS + OCR) is saved on the phone; the bill is created at sync and the money
/// is taken on the next visit. Money is never confirmed offline.
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
  Map<String, dynamic>? _codeInfo; // the server's code object once a code was requested for this bill
  int _resendAfter = 60;
  Map<String, dynamic>? _receipt;
  CapturedPhoto? _photo;
  bool _offerOffline = false; // the last request failed for lack of connection
  bool _savedOffline = false;

  final _queue = OfflineQueue.instance;

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
      if (!mounted) return;
      if (OfflineQueue.supported && OfflineQueue.isConnectionError(e)) {
        _queue.markOffline();
        final readingStep = _bill == null && _receipt == null;
        setState(() {
          _offerOffline = readingStep;
          _error = readingStep ? null : e.message; // on the reading step the offline banner explains it
        });
      } else {
        setState(() => _error = e.message);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadBill(int id) => _run(() async {
        final res = await ApiClient.instance.get('/bills/$id');
        _queue.markOnline();
        if (!mounted) return;
        final bill = Map<String, dynamic>.from(res as Map);
        Map<String, dynamic>? code;
        if (bill['status'] == 'awaiting_otp') {
          // a code may already be on the citizen's phone (e.g. sent before the app was closed)
          try {
            final s = await ApiClient.instance.get('/bills/$id/code-status');
            if (s is Map && s['state'] == 'sent') code = {'state': 'sent', 'expires_at': s['expires_at']};
            // mid-wait: the status carries the QR link and the number, so the waiting card shows without a resend
            if (s is Map && s['state'] == 'waiting' && s['wa_link'] != null) code = Map<String, dynamic>.from(s);
          } on ApiException catch (_) {
            // older server without code-status: the collector presses "send"
          }
        }
        if (!mounted) return;
        setState(() {
          _bill = bill;
          _codeInfo = code;
        });
      });

  /// Validates the reading form; returns the reading (null for an estimate).
  double? _checkedReading() {
    double? reading;
    if (!_useEstimate) {
      reading = double.tryParse(_readingController.text.trim());
      if (reading == null) {
        throw Exception('يرجى إدخال قراءة العداد بشكل صحيح');
      }
    }
    if (!_useEstimate && _photo == null) {
      throw Exception('يجب تصوير العداد قبل إصدار الفاتورة');
    }
    return reading;
  }

  Map<String, dynamic> _billBody(double? reading, GpsFix gps) => {
        'property_id': p['id'],
        'method': _useEstimate ? 'estimate' : 'reading',
        'current_reading': reading,
        'lat': gps.lat,
        'lng': gps.lng,
        'gps_accuracy_m': gps.accuracy,
        'is_mocked': gps.isMocked,
        'photo_base64': _photo?.base64,
        'ocr_reading': _useEstimate ? null : _photo?.ocrReading,
      };

  Future<void> _createBill() => _run(() async {
        _offerOffline = false;
        final reading = _checkedReading();
        final gps = await LocationService.current();
        final res = await ApiClient.instance.post('/bills', _billBody(reading, gps));
        _queue.markOnline();
        final bill = Map<String, dynamic>.from(res as Map);
        if (!mounted) return;
        setState(() {
          _bill = bill;
          final otp = bill['otp'];
          _codeInfo = otp is Map ? Map<String, dynamic>.from(otp) : null;
          if (_codeInfo != null) {
            _resendAfter = (asNum(_codeInfo!['resend_after_seconds']) ?? 60).toInt();
          }
        });
      });

  Future<void> _saveOffline() => _run(() async {
        final reading = _checkedReading();
        final gps = await LocationService.current(); // GPS works without internet
        await _queue.add(
          kind: 'reading',
          payload: _billBody(reading, gps),
          label: '${p['citizen_name'] ?? ''} (${p['property_code'] ?? ''})',
          capturedAt: DateTime.now(),
        );
        if (!mounted) return;
        setState(() {
          _savedOffline = true;
          _offerOffline = false;
          _error = null;
        });
      });

  Future<void> _takePhoto() => _run(() async {
        final photo = await PhotoService.capture(runOcr: true);
        if (photo == null || !mounted) return;
        setState(() {
          _photo = photo;
          if (photo.ocrReading != null && _readingController.text.trim().isEmpty) {
            final v = photo.ocrReading!;
            _readingController.text = v % 1 == 0 ? v.toInt().toString() : v.toString();
          }
        });
      });

  Future<void> _sendOtp() => _run(() async {
        final res = await ApiClient.instance.post('/bills/${_bill!['id']}/send-otp');
        if (!mounted) return;
        setState(() {
          _codeInfo = res is Map ? Map<String, dynamic>.from(res) : {'state': 'sent'};
          _resendAfter = (asNum(_codeInfo!['resend_after_seconds']) ?? 60).toInt();
        });
      });

  Future<void> _verify(String code, bool useMaster, String? reason) async {
    final res = await ApiClient.instance.post('/bills/${_bill!['id']}/verify', {
      'code': code,
      'use_master_code': useMaster,
      'reason': reason,
    });
    if (!mounted) return;
    setState(() => _receipt = Map<String, dynamic>.from(res as Map));
  }

  Future<Map<String, dynamic>?> _resend(String channel) async {
    final res = await ApiClient.instance.post('/bills/${_bill!['id']}/send-otp?channel=$channel');
    return res is Map ? Map<String, dynamic>.from(res) : null;
  }

  Future<Map<String, dynamic>> _status() async {
    final res = await ApiClient.instance.get('/bills/${_bill!['id']}/code-status');
    return Map<String, dynamic>.from(res as Map);
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _queue,
      builder: (context, _) {
        final offline = OfflineQueue.supported && (_queue.offline || _offerOffline);
        return Scaffold(
          appBar: portalAppBar(
            title: 'جباية ${p['property_code'] ?? ''}',
            color: AppColors.collector,
            subtitle: _firstVisit ? 'زيارة أولى' : null,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.lg),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _propertyHeader(),
                    // Optional, never blocks collection.
                    if (p['id'] is int && !_savedOffline) ...[
                      const SizedBox(height: Gap.xs),
                      PrevBillCard(propertyId: p['id'] as int),
                    ],
                    const SizedBox(height: Gap.sm),
                    if (_receipt != null)
                      ReceiptCard(receipt: _receipt!, onDone: () => Navigator.of(context).pop(true))
                    else if (_savedOffline)
                      _savedCard()
                    else if (_bill == null)
                      _readingCard(offline)
                    else
                      _billCard(),
                    if (_error != null) ...[
                      const SizedBox(height: Gap.md),
                      NoticeBanner(title: _error!, tone: Tone.bad),
                    ],
                  ],
                ),
              ),
            ),
          ),
          bottomNavigationBar: _bottom(offline),
        );
      },
    );
  }

  Widget? _bottom(bool offline) {
    if (_receipt != null) return null;
    if (_savedOffline) {
      return BottomActionBar(children: [
        PrimaryButton(label: 'إنهاء', icon: Icons.check, onPressed: () => Navigator.of(context).pop(false)),
      ]);
    }
    if (_bill == null) {
      if (offline) {
        return BottomActionBar(children: [
          PrimaryButton(label: 'حفظ القراءة للمزامنة لاحقاً', icon: Icons.save_alt, busy: _loading, onPressed: _saveOffline),
          TextButton(
            onPressed: _loading ? null : _createBill,
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            child: const Text('محاولة الإرسال الآن'),
          ),
        ]);
      }
      return BottomActionBar(children: [
        PrimaryButton(
          label: 'احتساب المبلغ وإرساله للمواطن',
          icon: Icons.calculate_outlined,
          busy: _loading,
          onPressed: _createBill,
        ),
      ]);
    }
    if (_bill!['status'] == 'awaiting_otp' && _codeInfo == null) {
      return BottomActionBar(children: [
        PrimaryButton(
          label: 'إرسال المبلغ والرمز إلى واتساب المواطن',
          icon: Icons.send,
          busy: _loading,
          onPressed: _sendOtp,
        ),
      ]);
    }
    return null;
  }

  Widget _propertyHeader() {
    return AppCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const CircleAvatar(
          radius: 22,
          backgroundColor: Color(0x1A0B5A52),
          child: Icon(Icons.home_outlined, color: AppColors.collector),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['citizen_name'] ?? ''}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text('${p['address'] ?? ''}', style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: Gap.xs),
            Text(
              '${meterStatusLabels[p['meter_status']] ?? ''}'
              '${p['last_reading'] != null ? '  ·  القراءة السابقة (مقفلة): ${formatNumber(asNum(p['last_reading']), decimals: 1)} م³' : ''}',
              style: const TextStyle(fontSize: 13),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _readingCard(bool offline) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('قراءة العداد', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: Gap.sm),
          if (offline)
            const NoticeBanner(
              tone: Tone.warn,
              icon: Icons.cloud_off,
              title: 'دون اتصال',
              message: 'لا يمكن استلام المال دون اتصال. ستُنشأ الفاتورة عند المزامنة وتُستلم في الزيارة القادمة',
            ),
          if (_firstVisit)
            const NoticeBanner(
              tone: Tone.info,
              title: 'زيارة أولى',
              message: 'تُسجَّل القراءة الحالية كقراءة أساس، ويُستوفى مبلغ تقديري عن الفترة. '
                  'الفواتير القادمة تُحسب على الفرق بين القراءتين.',
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _useEstimate,
            onChanged: _loading ? null : (v) => setState(() => _useEstimate = v ?? false),
            title: const Text('العداد عاطل / غير مقروء / غير موجود (تقدير)'),
            subtitle: _meterWorking && _useEstimate
                ? const Text('العداد مسجل كعامل: التقدير يحتاج موافقة المشرف', style: TextStyle(color: AppColors.warn))
                : null,
          ),
          OutlinedButton.icon(
            onPressed: _loading ? null : _takePhoto,
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(_photo == null
                ? (_useEstimate ? 'تصوير العداد (اختياري)' : 'تصوير العداد (إلزامي)')
                : 'إعادة التصوير'),
          ),
          if (_photo != null) ...[
            const SizedBox(height: Gap.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(Gap.radiusSm),
              child: Image.memory(_photo!.bytes, height: 180, fit: BoxFit.cover),
            ),
            if (_photo!.ocrReading != null)
              Padding(
                padding: const EdgeInsets.only(top: Gap.sm),
                child: Text('قراءة الكاميرا: ${_photo!.ocrReading}  (تأكد من مطابقتها للعداد)',
                    style: const TextStyle(color: AppColors.info, fontWeight: FontWeight.w600)),
              ),
          ],
          if (!_useEstimate) ...[
            const SizedBox(height: Gap.md),
            TextField(
              controller: _readingController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(labelText: 'القراءة الحالية على العداد (م³)', suffixText: 'م³'),
            ),
          ],
          const SizedBox(height: Gap.sm),
          Text(
            offline
                ? 'تُحفظ القراءة مع الصورة والموقع على الهاتف، وتُرسل للخادم تلقائياً عند عودة الإنترنت.'
                : 'المبلغ يُحسب في الخادم ويُرسل للمواطن عبر واتساب مع تنبيه بعدم دفع أكثر منه.',
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _savedCard() {
    return const Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      NoticeBanner(
        tone: Tone.good,
        icon: Icons.save_alt,
        title: 'حُفظت القراءة على الهاتف',
        message: 'ستُرسل تلقائياً عند عودة الإنترنت (أو من زر المزامنة).',
      ),
      NoticeBanner(
        tone: Tone.warn,
        icon: Icons.payments_outlined,
        title: 'لا تستلم أي مبلغ الآن',
        message: 'لا يمكن استلام المال دون اتصال. ستُنشأ الفاتورة عند المزامنة وتُستلم في الزيارة القادمة',
      ),
    ]);
  }

  Widget _billCard() {
    final b = _bill!;
    final status = b['status'] as String;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              b['visit_type'] == 'first_visit' ? 'فاتورة الزيارة الأولى (تقديرية)' : 'فاتورة دورية',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: Gap.sm),
            const Divider(),
            if (b['previous_reading'] != null) _row('القراءة السابقة', '${formatNumber(asNum(b['previous_reading']), decimals: 1)} م³'),
            if (b['current_reading'] != null) _row('القراءة الحالية', '${formatNumber(asNum(b['current_reading']), decimals: 1)} م³'),
            if (b['consumption'] != null) _row('الاستهلاك', '${formatNumber(asNum(b['consumption']), decimals: 1)} م³'),
            _row('مدة الفترة', '${b['period_days']} يوم'),
            _row('طريقة الاحتساب', b['billing_method'] == 'reading' ? 'حسب القراءة' : 'تقديري'),
            _row('رسوم الاستهلاك', formatIqd(asNum(b['gov_amount']))),
            _row('أجور الجباية', formatIqd(asNum(b['company_fee']))),
            const Divider(),
            const SizedBox(height: Gap.sm),
            const Text('المبلغ المطلوب', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
            Text(
              formatIqd(asNum(b['total_amount'])),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: AppColors.good),
            ),
          ],
        ),
      ),
      const SizedBox(height: Gap.sm),
      if (status == 'awaiting_otp' && _codeInfo != null)
        AppCard(
          child: OtpPanel(
            key: ValueKey('otp-${b['id']}'),
            phoneMasked: (b['phone_masked'] ?? '').toString(),
            code: _codeInfo,
            resendAfterSeconds: _resendAfter,
            verifyLabel: 'تأكيد الدفع وإصدار الوصل',
            onVerify: _verify,
            onResend: _resend,
            onStatus: _status,
          ),
        )
      else if (status == 'awaiting_otp')
        const NoticeBanner(
          tone: Tone.info,
          title: 'الخطوة التالية',
          message: 'أرسل المبلغ ورمز التحقق إلى واتساب المواطن من الزر في الأسفل.',
        )
      else if (status == 'pending_approval')
        const NoticeBanner(tone: Tone.warn, title: 'بانتظار موافقة المشرف على التقدير', message: 'حدّث الحالة بعد الموافقة.')
      else if (status == 'blocked_review')
        const NoticeBanner(
          tone: Tone.bad,
          title: 'تم إيقاف الجباية',
          message: 'القراءة الحالية أقل من السابقة. تمت إحالة الفاتورة للمشرف.',
        )
      else if (status == 'cancelled')
        NoticeBanner(
          tone: Tone.neutral,
          title: 'تم رفض الفاتورة',
          message: b['review_note'] != null ? '${b['review_note']}' : null,
        ),
      if (status == 'pending_approval' || status == 'blocked_review')
        OutlinedButton.icon(
          onPressed: _loading ? null : () => _loadBill(b['id'] as int),
          icon: const Icon(Icons.refresh),
          label: const Text('تحديث الحالة'),
        ),
      if (status == 'cancelled')
        OutlinedButton(
          onPressed: () => setState(() {
            _bill = null;
            _codeInfo = null;
          }),
          child: const Text('إصدار فاتورة جديدة'),
        ),
    ]);
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppColors.muted)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
