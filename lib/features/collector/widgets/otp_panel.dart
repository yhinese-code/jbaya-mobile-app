import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api_client.dart';

/// Code entry used for both registration and payment.
/// The code is sent by the SERVER to the citizen's WhatsApp; the collector only types what the citizen reads out.
/// Fallback: the rotating master code from Central Command, with a mandatory reason.
class OtpPanel extends StatefulWidget {
  final String phoneMasked;
  final int resendAfterSeconds;
  final Future<void> Function(String code, bool useMasterCode, String? reason) onVerify;
  final Future<int?> Function() onResend;
  final String verifyLabel;

  const OtpPanel({
    super.key,
    required this.phoneMasked,
    required this.onVerify,
    required this.onResend,
    this.resendAfterSeconds = 60,
    this.verifyLabel = 'تأكيد الرمز',
  });

  @override
  State<OtpPanel> createState() => _OtpPanelState();
}

class _OtpPanelState extends State<OtpPanel> {
  final _codeController = TextEditingController();
  final _reasonController = TextEditingController();
  bool _useMaster = false;
  bool _busy = false;
  String? _error;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCooldown(widget.resendAfterSeconds);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _startCooldown(int seconds) {
    _timer?.cancel();
    setState(() => _cooldown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_cooldown <= 1) {
        t.cancel();
        setState(() => _cooldown = 0);
      } else {
        setState(() => _cooldown--);
      }
    });
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (code.length < 4) {
      setState(() => _error = 'يرجى إدخال الرمز كاملاً');
      return;
    }
    if (_useMaster && _reasonController.text.trim().length < 5) {
      setState(() => _error = 'يجب كتابة سبب استخدام الرمز الرئيسي');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onVerify(code, _useMaster, _useMaster ? _reasonController.text.trim() : null);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final cooldown = await widget.onResend();
      if (!mounted) return;
      _codeController.clear();
      _startCooldown(cooldown ?? widget.resendAfterSeconds);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إرسال رمز جديد إلى واتساب المواطن'), backgroundColor: Colors.blueGrey),
        );
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.blue.shade200),
          ),
          child: Row(
            children: [
              const Icon(Icons.chat, color: Colors.green),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _useMaster
                      ? 'أدخل الرمز الرئيسي الذي تبلغك به غرفة القيادة'
                      : 'تم إرسال الرمز إلى واتساب المواطن (${widget.phoneMasked}). اطلب من المواطن قراءته لك.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            labelText: _useMaster ? 'الرمز الرئيسي' : 'رمز المواطن (6 أرقام)',
            border: const OutlineInputBorder(),
            counterText: '',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _useMaster,
          onChanged: _busy ? null : (v) => setState(() => _useMaster = v),
          title: const Text('المواطن لا يملك واتساب / لم يصل الرمز'),
          subtitle: const Text('استخدام الرمز الرئيسي من القيادة (يُسجَّل ويُراجَع)', style: TextStyle(fontSize: 12)),
        ),
        if (_useMaster)
          TextField(
            controller: _reasonController,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'سبب استخدام الرمز الرئيسي (إلزامي)',
              border: OutlineInputBorder(),
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        ],
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: _busy ? null : _verify,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orange.shade800,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: _busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : Text(widget.verifyLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (!_useMaster)
          TextButton(
            onPressed: (_busy || _cooldown > 0) ? null : _resend,
            child: Text(_cooldown > 0 ? 'إعادة الإرسال بعد $_cooldown ثانية' : 'إعادة إرسال الرمز'),
          ),
      ],
    );
  }
}
