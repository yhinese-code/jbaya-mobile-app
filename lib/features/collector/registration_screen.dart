import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/location_service.dart';
import '../../core/offline_queue.dart';
import '../../core/theme.dart';
import 'collection_screen.dart';
import 'widgets/otp_panel.dart';
import 'widgets/step_indicator.dart';

/// Flow A: citizen details + real GPS -> the server sends the code to the citizen's WhatsApp (at once, or after the
/// citizen messages the company number) -> verify -> first-visit collection.
/// Offline (mobile): the registration is saved on the phone and sent with the next sync.
class RegistrationScreen extends StatefulWidget {
  final VoidCallback? onCollected;
  const RegistrationScreen({super.key, this.onCollected});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  int _step = 1; // 1 details, 2 code, 3 done
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  final _serialController = TextEditingController();
  final _accountController = TextEditingController();
  String _propertyClass = 'Household';
  String _meterStatus = 'working';
  int _formVersion = 0; // forces dropdowns to rebuild after reset

  GpsFix? _gps;
  DateTime? _gpsAt;
  bool _gettingGps = false;
  bool _loading = false;
  String? _error;
  bool _offerOffline = false;   // the last send failed for lack of connection
  bool _savedOffline = false;   // step 3 after saving on the phone
  String? _businessNumber;      // shown after an offline save (remembered from an earlier code screen)

  Map<String, dynamic>? _registration; // response of POST /registrations
  Map<String, dynamic>? _verified;     // response of verify

  final _queue = OfflineQueue.instance;

  @override
  void initState() {
    super.initState();
    if (OfflineQueue.supported) _queue.init();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _serialController.dispose();
    _accountController.dispose();
    super.dispose();
  }

  Future<void> _captureGps() async {
    setState(() {
      _gettingGps = true;
      _error = null;
    });
    try {
      final fix = await LocationService.current();
      if (mounted) {
        setState(() {
          _gps = fix;
          _gpsAt = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _gettingGps = false);
    }
  }

  bool _validate() {
    if (_gps == null) {
      setState(() => _error = 'يجب التقاط الموقع الجغرافي أولاً');
      return false;
    }
    if (_nameController.text.trim().length < 3 || _addressController.text.trim().length < 3 || _phoneController.text.trim().isEmpty) {
      setState(() => _error = 'يرجى إكمال الاسم والعنوان ورقم الواتساب');
      return false;
    }
    return true;
  }

  /// The exact body of POST /registrations (also what an offline item carries).
  Map<String, dynamic> _body() => {
        'full_name': _nameController.text.trim(),
        'address': _addressController.text.trim(),
        'property_class': _propertyClass,
        'whatsapp_phone': _phoneController.text.trim(),
        'lat': _gps!.lat,
        'lng': _gps!.lng,
        'gps_accuracy_m': _gps!.accuracy,
        'is_mocked': _gps!.isMocked,
        'meter_status': _meterStatus,
        'meter_serial': _serialController.text.trim().isEmpty ? null : _serialController.text.trim(),
        'account_no': _accountController.text.trim().isEmpty ? null : _accountController.text.trim(),
      };

  Future<void> _start() async {
    if (!_validate()) return;
    setState(() {
      _loading = true;
      _error = null;
      _offerOffline = false;
    });
    try {
      final res = await ApiClient.instance.post('/registrations', _body());
      _queue.markOnline();
      if (!mounted) return;
      setState(() {
        _registration = Map<String, dynamic>.from(res as Map);
        _step = 2;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (OfflineQueue.supported && OfflineQueue.isConnectionError(e)) {
        _queue.markOffline();
        setState(() {
          _offerOffline = true;
          _error = null;
        });
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveOffline() async {
    if (!_validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _queue.add(
        kind: 'registration',
        payload: _body(),
        label: '${_nameController.text.trim()} - ${_addressController.text.trim()}',
        capturedAt: _gpsAt ?? DateTime.now(),
      );
      final number = await _queue.businessNumber();
      if (!mounted) return;
      setState(() {
        _savedOffline = true;
        _businessNumber = number;
        _offerOffline = false;
        _step = 3;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر الحفظ على الهاتف: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verify(String code, bool useMaster, String? reason) async {
    final res = await ApiClient.instance.post('/registrations/${_registration!['property_id']}/verify', {
      'code': code,
      'use_master_code': useMaster,
      'reason': reason,
    });
    if (!mounted) return;
    setState(() {
      _verified = Map<String, dynamic>.from(res as Map);
      _step = 3;
    });
  }

  Future<Map<String, dynamic>?> _resend(String channel) async {
    final res = await ApiClient.instance.post('/registrations/${_registration!['property_id']}/resend-otp?channel=$channel');
    if (res is! Map) return null;
    final code = res['code'] is Map ? Map<String, dynamic>.from(res['code'] as Map) : <String, dynamic>{'state': 'sent'};
    code['resend_after_seconds'] ??= res['resend_after_seconds'];
    return code;
  }

  Future<Map<String, dynamic>> _status() async {
    final res = await ApiClient.instance.get('/registrations/${_registration!['property_id']}/code-status');
    return Map<String, dynamic>.from(res as Map);
  }

  Future<void> _goToFirstCollection() async {
    final property = <String, dynamic>{
      'id': _registration!['property_id'],
      'property_code': _registration!['property_code'],
      'citizen_name': _nameController.text.trim(),
      'address': _addressController.text.trim(),
      'meter_status': _meterStatus,
      'last_reading': null,
      'never_paid': true,
      'open_bill_id': null,
    };
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CollectionScreen(property: property)));
    widget.onCollected?.call();
    if (mounted) _reset();
  }

  void _reset() {
    setState(() {
      _step = 1;
      _formVersion++;
      _nameController.clear();
      _addressController.clear();
      _phoneController.clear();
      _serialController.clear();
      _accountController.clear();
      _propertyClass = 'Household';
      _meterStatus = 'working';
      _gps = null;
      _gpsAt = null;
      _registration = null;
      _verified = null;
      _error = null;
      _offerOffline = false;
      _savedOffline = false;
    });
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _queue,
      builder: (context, _) {
        final offline = OfflineQueue.supported && _queue.offline;
        return Column(
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
              child: StepIndicator(labels: const ['البيانات والموقع', 'رمز المواطن', 'تم التسجيل'], current: _step),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Gap.lg),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_step == 1) ..._detailsForm(offline),
                        if (_step == 2) _codeStep(),
                        if (_step == 3) ..._done(),
                        if (_error != null) ...[
                          const SizedBox(height: Gap.md),
                          NoticeBanner(title: _error!, tone: Tone.bad),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_step == 1) _detailsActions(offline),
            if (_step == 3) _doneActions(),
          ],
        );
      },
    );
  }

  Widget _codeStep() {
    final r = _registration!;
    final code = r['code'] is Map ? Map<String, dynamic>.from(r['code'] as Map) : null;
    if (code != null) code['resend_after_seconds'] ??= r['resend_after_seconds'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppCard(
        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
        child: Row(children: [
          const Icon(Icons.home_work_outlined, color: AppColors.collector),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Text('${_nameController.text.trim()}\n${r['property_code'] ?? ''}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
      const SizedBox(height: Gap.sm),
      OtpPanel(
        phoneMasked: (r['phone_masked'] ?? '').toString(),
        code: code,
        resendAfterSeconds: (asNum(r['resend_after_seconds']) ?? 60).toInt(),
        verifyLabel: 'تأكيد الرمز وربط رقم المواطن',
        onVerify: _verify,
        onResend: _resend,
        onStatus: _status,
      ),
    ]);
  }

  List<Widget> _detailsForm(bool offline) {
    final captured = _gps != null;
    return [
      if (offline && !_offerOffline)
        const NoticeBanner(
          tone: Tone.warn,
          icon: Icons.cloud_off,
          title: 'دون اتصال',
          message: 'يمكنك إكمال البيانات وحفظ التسجيل على الهاتف، ويُرسل تلقائياً عند عودة الإنترنت.',
        ),
      AppCard(
        accent: captured ? AppColors.good : AppColors.warn,
        child: Row(
          children: [
            Icon(Icons.location_pin, color: captured ? AppColors.good : AppColors.warn),
            const SizedBox(width: Gap.md),
            Expanded(
              child: Text(
                captured
                    ? 'تم التقاط الموقع (دقة ${_gps!.accuracy.toStringAsFixed(0)} م)'
                    : 'يجب التقاط الموقع الجغرافي (إلزامي)',
                style: TextStyle(fontWeight: FontWeight.w600, color: captured ? AppColors.good : AppColors.warn),
              ),
            ),
            const SizedBox(width: Gap.sm),
            captured
                ? OutlinedButton(
                    onPressed: _gettingGps ? null : _captureGps,
                    child: _gettingGps ? _spinner(dark: true) : const Text('إعادة الالتقاط'),
                  )
                : FilledButton.icon(
                    onPressed: _gettingGps ? null : _captureGps,
                    style: FilledButton.styleFrom(backgroundColor: AppColors.warn),
                    icon: _gettingGps ? _spinner() : const Icon(Icons.my_location),
                    label: const Text('التقاط الموقع'),
                  ),
          ],
        ),
      ),
      const SizedBox(height: Gap.lg),
      TextField(
        controller: _nameController,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(labelText: 'الاسم الكامل للساكن/المالك', prefixIcon: Icon(Icons.person_outline)),
      ),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _addressController,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(labelText: 'العنوان الرسمي (زقاق/دار)', prefixIcon: Icon(Icons.signpost_outlined)),
      ),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _phoneController,
        keyboardType: TextInputType.phone,
        decoration: const InputDecoration(
          labelText: 'رقم واتساب الساكن',
          hintText: '07XXXXXXXXX',
          prefixIcon: Icon(Icons.chat_outlined),
        ),
      ),
      const SizedBox(height: Gap.md),
      DropdownButtonFormField<String>(
        key: ValueKey('class-$_formVersion'),
        initialValue: _propertyClass,
        decoration: const InputDecoration(labelText: 'فئة العقار'),
        items: propertyClassLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
        onChanged: (v) => setState(() => _propertyClass = v ?? 'Household'),
      ),
      const SizedBox(height: Gap.md),
      DropdownButtonFormField<String>(
        key: ValueKey('meter-$_formVersion'),
        initialValue: _meterStatus,
        decoration: const InputDecoration(labelText: 'حالة العداد'),
        items: meterStatusLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
        onChanged: (v) => setState(() => _meterStatus = v ?? 'working'),
      ),
      if (_meterStatus == 'working') ...[
        const SizedBox(height: Gap.md),
        TextField(controller: _serialController, decoration: const InputDecoration(labelText: 'الرقم التسلسلي للعداد (اختياري)')),
      ],
      const SizedBox(height: Gap.md),
      TextField(
        controller: _accountController,
        decoration: const InputDecoration(labelText: 'رقم الحساب في دائرة الماء (من الفاتورة القديمة، اختياري)'),
      ),
      if (_offerOffline) ...[
        const SizedBox(height: Gap.md),
        const NoticeBanner(
          tone: Tone.warn,
          icon: Icons.cloud_off,
          title: 'تعذر الاتصال بالخادم',
          message: 'يمكنك حفظ التسجيل على الهاتف (مع الموقع) وسيُرسل عند عودة الإنترنت. '
              'يتفعّل العقار عندما يرسل المواطن رسالة واتساب إلى رقم الشركة، أو برمز التحقق في الزيارة القادمة.',
        ),
      ],
    ];
  }

  Widget _detailsActions(bool offline) {
    final saveFirst = OfflineQueue.supported && (offline || _offerOffline);
    if (saveFirst) {
      return BottomActionBar(children: [
        PrimaryButton(
          label: 'حفظ للمزامنة لاحقاً',
          icon: Icons.save_alt,
          busy: _loading,
          onPressed: _saveOffline,
        ),
        TextButton(
          onPressed: _loading ? null : _start,
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          child: const Text('محاولة الإرسال الآن'),
        ),
      ]);
    }
    return BottomActionBar(children: [
      PrimaryButton(
        label: 'إرسال رمز التحقق إلى واتساب المواطن',
        icon: Icons.send,
        busy: _loading,
        onPressed: _start,
      ),
    ]);
  }

  List<Widget> _done() {
    if (_savedOffline) {
      final number = formatWhatsappNumber(_businessNumber);
      return [
        const NoticeBanner(
          tone: Tone.good,
          icon: Icons.save_alt,
          title: 'حُفظ التسجيل على الهاتف',
          message: 'سيُرسل إلى الخادم تلقائياً عند عودة الإنترنت (أو من زر المزامنة).',
        ),
        NoticeBanner(
          tone: Tone.info,
          icon: Icons.chat_outlined,
          title: 'تفعيل العقار',
          message: 'يتفعّل العقار عندما يرسل المواطن أي رسالة واتساب إلى رقم الشركة'
              '${number.isEmpty ? '' : ' ($number)'}، أو برمز التحقق في الزيارة القادمة. '
              'لا تستلم أي مبلغ قبل التفعيل.',
        ),
        if (number.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Center(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: SelectableText(number, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
            ),
          ),
        ],
      ];
    }
    final viaMaster = _verified?['verification_method'] == 'master_code';
    return [
      NoticeBanner(
        tone: Tone.good,
        title: 'تم تسجيل العقار ${_registration!['property_code']}',
        message: 'تم ربط رقم المواطن بالعقار.',
      ),
      if (viaMaster)
        const NoticeBanner(tone: Tone.warn, title: 'تم التأكيد بالرمز الرئيسي', message: 'العملية مسجلة للمراجعة'),
    ];
  }

  Widget _doneActions() {
    if (_savedOffline) {
      return BottomActionBar(children: [
        PrimaryButton(label: 'تسجيل عقار آخر', icon: Icons.person_add_alt_1, onPressed: _reset),
      ]);
    }
    return BottomActionBar(children: [
      PrimaryButton(label: 'متابعة: جباية الزيارة الأولى', icon: Icons.payments_outlined, onPressed: _goToFirstCollection),
      TextButton(
        onPressed: _reset,
        style: TextButton.styleFrom(minimumSize: const Size.fromHeight(44)),
        child: const Text('تسجيل عقار آخر'),
      ),
    ]);
  }

  Widget _spinner({bool dark = false}) => SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: dark ? AppColors.brand : Colors.white),
      );
}
