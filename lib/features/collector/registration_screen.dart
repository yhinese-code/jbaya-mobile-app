import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/location_service.dart';
import 'collection_screen.dart';
import 'widgets/otp_panel.dart';

/// Flow A: citizen details + real GPS -> server sends OTP to the citizen's WhatsApp -> verify -> first-visit collection.
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
  String _propertyClass = 'Household';
  String _meterStatus = 'working';
  int _formVersion = 0; // forces dropdowns to rebuild after reset

  GpsFix? _gps;
  bool _gettingGps = false;
  bool _loading = false;
  String? _error;

  Map<String, dynamic>? _registration; // response of POST /registrations
  Map<String, dynamic>? _verified;     // response of verify

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _serialController.dispose();
    super.dispose();
  }

  Future<void> _captureGps() async {
    setState(() {
      _gettingGps = true;
      _error = null;
    });
    try {
      final fix = await LocationService.current();
      if (mounted) setState(() => _gps = fix);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _gettingGps = false);
    }
  }

  Future<void> _start() async {
    if (_gps == null) {
      setState(() => _error = 'يجب التقاط الموقع الجغرافي أولاً');
      return;
    }
    if (_nameController.text.trim().length < 3 || _addressController.text.trim().length < 3 || _phoneController.text.trim().isEmpty) {
      setState(() => _error = 'يرجى إكمال الاسم والعنوان ورقم الواتساب');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.post('/registrations', {
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
      });
      if (!mounted) return;
      setState(() {
        _registration = Map<String, dynamic>.from(res as Map);
        _step = 2;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
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

  Future<int?> _resend() async {
    final res = await ApiClient.instance.post('/registrations/${_registration!['property_id']}/resend-otp');
    return asNum(res['resend_after_seconds'])?.toInt();
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
      _propertyClass = 'Household';
      _meterStatus = 'working';
      _gps = null;
      _registration = null;
      _verified = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _step == 1 ? '1. التثبيت المكاني وبيانات الساكن' : (_step == 2 ? '2. رمز التحقق من المواطن' : '3. تم التسجيل'),
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF004D40)),
                  ),
                  const SizedBox(height: 16),
                  if (_step == 1) ..._detailsForm(),
                  if (_step == 2)
                    OtpPanel(
                      phoneMasked: (_registration!['phone_masked'] ?? '').toString(),
                      resendAfterSeconds: (asNum(_registration!['resend_after_seconds']) ?? 60).toInt(),
                      verifyLabel: 'تأكيد الرمز وربط رقم المواطن',
                      onVerify: _verify,
                      onResend: _resend,
                    ),
                  if (_step == 3) ..._done(),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _detailsForm() {
    final captured = _gps != null;
    return [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: captured ? Colors.green.shade50 : Colors.orange.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: captured ? Colors.green : Colors.orange),
        ),
        child: Row(
          children: [
            Icon(Icons.location_pin, color: captured ? Colors.green : Colors.orange),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                captured
                    ? 'تم التقاط الموقع (دقة ${_gps!.accuracy.toStringAsFixed(0)} م)'
                    : 'يجب التقاط الموقع الجغرافي (إلزامي)',
                style: TextStyle(fontWeight: FontWeight.bold, color: captured ? Colors.green.shade900 : Colors.orange.shade900),
              ),
            ),
            ElevatedButton(
              onPressed: _gettingGps ? null : _captureGps,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
              child: _gettingGps
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : Text(captured ? 'إعادة الالتقاط' : 'التقاط GIS'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'الاسم الكامل للساكن/المالك', border: OutlineInputBorder())),
      const SizedBox(height: 10),
      TextField(controller: _addressController, decoration: const InputDecoration(labelText: 'العنوان الرسمي (زقاق/دار)', border: OutlineInputBorder())),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        key: ValueKey('class-$_formVersion'),
        initialValue: _propertyClass,
        decoration: const InputDecoration(labelText: 'فئة العقار', border: OutlineInputBorder()),
        items: propertyClassLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
        onChanged: (v) => setState(() => _propertyClass = v ?? 'Household'),
      ),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        key: ValueKey('meter-$_formVersion'),
        initialValue: _meterStatus,
        decoration: const InputDecoration(labelText: 'حالة العداد', border: OutlineInputBorder()),
        items: meterStatusLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
        onChanged: (v) => setState(() => _meterStatus = v ?? 'working'),
      ),
      if (_meterStatus == 'working') ...[
        const SizedBox(height: 10),
        TextField(controller: _serialController, decoration: const InputDecoration(labelText: 'الرقم التسلسلي للعداد (اختياري)', border: OutlineInputBorder())),
      ],
      const SizedBox(height: 10),
      TextField(
        controller: _phoneController,
        keyboardType: TextInputType.phone,
        decoration: const InputDecoration(labelText: 'رقم واتساب الساكن', hintText: '07XXXXXXXXX', border: OutlineInputBorder()),
      ),
      const SizedBox(height: 12),
      ElevatedButton(
        onPressed: _loading ? null : _start,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF004D40),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        child: _loading
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Text('إرسال رمز التحقق إلى واتساب المواطن'),
      ),
    ];
  }

  List<Widget> _done() {
    final viaMaster = _verified?['verification_method'] == 'master_code';
    return [
      Text(
        '✅ تم تسجيل العقار ${_registration!['property_code']} وربط رقم المواطن',
        style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 16),
      ),
      if (viaMaster)
        Text('تم التأكيد بالرمز الرئيسي - العملية مسجلة للمراجعة', style: TextStyle(color: Colors.orange.shade900)),
      const SizedBox(height: 16),
      ElevatedButton.icon(
        onPressed: _goToFirstCollection,
        icon: const Icon(Icons.payments),
        label: const Text('متابعة: جباية الزيارة الأولى'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF004D40),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
      TextButton(onPressed: _reset, child: const Text('تسجيل عقار آخر')),
    ];
  }
}
