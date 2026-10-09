import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/offline_queue.dart';
import '../../core/theme.dart';
import 'widgets/otp_panel.dart';
import 'widgets/step_indicator.dart';

/// Confirms the citizen's number for a house registered offline (status pending_otp).
/// Same code step as live registration; no billing here (the server refuses bills for pending houses).
/// Pops true when the house was activated.
class VerifyHouseScreen extends StatefulWidget {
  /// Route item: id, property_code, citizen_name, address
  final Map<String, dynamic> property;
  const VerifyHouseScreen({super.key, required this.property});

  @override
  State<VerifyHouseScreen> createState() => _VerifyHouseScreenState();
}

class _VerifyHouseScreenState extends State<VerifyHouseScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _code;   // code object for the panel (null = not started yet)
  String _phoneMasked = '';
  int _resendAfter = 60;
  Map<String, dynamic>? _verified;

  Map<String, dynamic> get p => widget.property;
  String get _base => '/registrations/${p['id']}';

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  /// A code may already be on its way (sent, or waiting for the citizen's message): resume it without a resend.
  Future<void> _checkStatus() async {
    try {
      final s = await ApiClient.instance.get('$_base/code-status');
      if (!mounted) return;
      if (s is Map && (s['state'] == 'sent' || (s['state'] == 'waiting' && s['wa_link'] != null))) {
        setState(() => _code = Map<String, dynamic>.from(s));
      }
    } on ApiException catch (e) {
      if (mounted && OfflineQueue.isConnectionError(e)) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic>? _unwrap(dynamic res) {
    if (res is! Map) return null;
    _phoneMasked = (res['phone_masked'] ?? _phoneMasked).toString();
    _resendAfter = (asNum(res['resend_after_seconds']) ?? _resendAfter).toInt();
    final code = res['code'] is Map ? Map<String, dynamic>.from(res['code'] as Map) : <String, dynamic>{'state': 'sent'};
    code['resend_after_seconds'] ??= res['resend_after_seconds'];
    return code;
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.post('$_base/resend-otp?channel=auto');
      if (!mounted) return;
      setState(() => _code = _unwrap(res));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Map<String, dynamic>?> _resend(String channel) async {
    final res = await ApiClient.instance.post('$_base/resend-otp?channel=$channel');
    final code = _unwrap(res);
    if (mounted) setState(() {});
    return code;
  }

  Future<Map<String, dynamic>> _status() async {
    final res = await ApiClient.instance.get('$_base/code-status');
    return Map<String, dynamic>.from(res as Map);
  }

  Future<void> _verify(String code, bool useMaster, String? reason) async {
    final res = await ApiClient.instance.post('$_base/verify', {
      'code': code,
      'use_master_code': useMaster,
      'reason': reason,
    });
    if (!mounted) return;
    setState(() => _verified = Map<String, dynamic>.from(res as Map));
  }

  @override
  Widget build(BuildContext context) {
    final done = _verified != null;
    return Scaffold(
      appBar: portalAppBar(title: 'تأكيد رقم المواطن', subtitle: '${p['property_code'] ?? ''}', color: AppColors.collector),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.lg),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppCard(
                  child: Row(children: [
                    const Icon(Icons.home_work_outlined, color: AppColors.collector),
                    const SizedBox(width: Gap.md),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${p['citizen_name'] ?? ''}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                        Text('${p['address'] ?? ''}', style: const TextStyle(color: AppColors.muted)),
                      ]),
                    ),
                  ]),
                ),
                const SizedBox(height: Gap.sm),
                if (done)
                  NoticeBanner(
                    tone: Tone.good,
                    title: 'تم تأكيد رقم المواطن وتفعيل العقار ${p['property_code'] ?? ''}',
                    message: _verified!['verification_method'] == 'master_code'
                        ? 'تم التأكيد بالرمز الرئيسي - العملية مسجلة للمراجعة'
                        : 'يمكنك الآن الجباية من قائمة الجباية الدورية.',
                  )
                else if (_loading && _code == null)
                  const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()))
                else if (_code == null)
                  const NoticeBanner(
                    tone: Tone.warn,
                    icon: Icons.phonelink_lock_outlined,
                    title: 'بانتظار تأكيد رقم المواطن',
                    message: 'سُجّل هذا العقار دون اتصال. أكّد رقم واتساب المواطن برمز التحقق قبل أي جباية.',
                  )
                else
                  AppCard(
                    child: OtpPanel(
                      phoneMasked: _phoneMasked,
                      code: _code,
                      resendAfterSeconds: _resendAfter,
                      verifyLabel: 'تأكيد الرمز وتفعيل العقار',
                      onVerify: _verify,
                      onResend: _resend,
                      onStatus: _status,
                    ),
                  ),
                if (_error != null) NoticeBanner(tone: Tone.bad, title: _error!),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: done
          ? BottomActionBar(children: [
              PrimaryButton(label: 'إنهاء', icon: Icons.check, onPressed: () => Navigator.of(context).pop(true)),
            ])
          : (_code == null && !(_loading && _code == null)
              ? BottomActionBar(children: [
                  PrimaryButton(
                    label: 'إرسال رمز التحقق إلى المواطن',
                    icon: Icons.send,
                    busy: _loading,
                    onPressed: _start,
                  ),
                ])
              : null),
    );
  }
}
