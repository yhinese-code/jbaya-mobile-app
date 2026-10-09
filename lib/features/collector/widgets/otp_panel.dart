import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/api_client.dart';
import '../../../core/format.dart';
import '../../../core/offline_queue.dart';
import '../../../core/theme.dart';
import '../../shared/ui.dart' show confirm;

/// Code step used for both registration and payment (citizen-first flow).
///
/// The server either sends the code at once (the citizen's free WhatsApp window is open: state "sent"), or waits for
/// the citizen to message the company number first (state "waiting"): the screen then shows a QR / the number, polls
/// code-status every 3 seconds and switches to code entry when the code has gone out. The plain code never reaches
/// this app: the collector types what the citizen reads out.
/// Fallbacks: the paid template message (channel=template), and the rotating master code with a mandatory reason.
class OtpPanel extends StatefulWidget {
  final String phoneMasked;

  /// The server's `code` object: {state, channel, expires_at, wait_id?, business_number?, wa_link?, instructions?,
  /// resend_after_seconds?}. Null (older server) = the code was already sent.
  final Map<String, dynamic>? code;
  final int resendAfterSeconds;
  final Future<void> Function(String code, bool useMasterCode, String? reason) onVerify;

  /// Asks the server to send again; channel is 'auto' or 'template'. Returns the new code object (or null).
  final Future<Map<String, dynamic>?> Function(String channel) onResend;

  /// GET .../code-status -> {state: waiting|sent|expired|none, expires_at?}. Null disables polling.
  final Future<Map<String, dynamic>> Function()? onStatus;
  final String verifyLabel;

  const OtpPanel({
    super.key,
    required this.phoneMasked,
    required this.onVerify,
    required this.onResend,
    this.code,
    this.onStatus,
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

  // delivery state
  String _state = 'sent'; // sent | waiting | expired
  String? _channel;
  DateTime? _expiresAt;
  String? _waLink;
  String? _businessNumber;
  String? _instructions;

  int _cooldown = 0;
  Timer? _cooldownTimer;
  Timer? _pollTimer;
  Timer? _clock;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _apply(widget.code, initial: true);
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _pollTimer?.cancel();
    _clock?.cancel();
    _codeController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ state

  void _apply(Map<String, dynamic>? code, {bool initial = false}) {
    final c = code ?? const <String, dynamic>{};
    final state = (c['state'] ?? 'sent').toString();
    void set() {
      _state = state == 'waiting' ? 'waiting' : (state == 'expired' || state == 'none' ? 'expired' : 'sent');
      _channel = c['channel']?.toString() ?? (_state == 'sent' ? _channel : null);
      _expiresAt = DateTime.tryParse('${c['expires_at'] ?? ''}')?.toLocal();
      if (c['wa_link'] != null) _waLink = c['wa_link'].toString();
      if (c['business_number'] != null) _businessNumber = c['business_number'].toString();
      if (c['instructions'] != null) _instructions = c['instructions'].toString();
    }

    if (initial) {
      set();
    } else {
      setState(set);
    }
    unawaited(OfflineQueue.instance.rememberBusinessNumber(_businessNumber));
    if (_state == 'waiting') {
      _startWaiting();
    } else {
      _stopWaiting();
      if (_state == 'sent') {
        _startCooldown((asNum(c['resend_after_seconds']) ?? widget.resendAfterSeconds).toInt(), initial: initial);
      }
    }
  }

  void _startWaiting() {
    _pollTimer?.cancel();
    _clock?.cancel();
    if (widget.onStatus != null) {
      _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    }
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final left = _secondsLeft;
      // a few seconds of grace for the server's own answer, then give up locally
      if (left != null && left < -5 && _state == 'waiting') {
        _stopWaiting();
        setState(() => _state = 'expired');
        return;
      }
      setState(() {});
    });
  }

  void _stopWaiting() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _clock?.cancel();
    _clock = null;
  }

  int? get _secondsLeft => _expiresAt?.difference(DateTime.now()).inSeconds;

  Future<void> _poll() async {
    if (_polling || !mounted || _state != 'waiting') return;
    _polling = true;
    try {
      final s = await widget.onStatus!();
      if (!mounted || _state != 'waiting') return;
      final state = '${s['state']}';
      if (state == 'sent') {
        _apply({'state': 'sent', 'channel': 'free', 'expires_at': s['expires_at']});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('وصل الرمز إلى واتساب المواطن'), backgroundColor: AppColors.good),
          );
        }
      } else if (state == 'expired' || state == 'none') {
        _stopWaiting();
        setState(() => _state = 'expired');
      } else {
        setState(() {
          if (s['expires_at'] != null) _expiresAt = DateTime.tryParse('${s['expires_at']}')?.toLocal() ?? _expiresAt;
          if (s['wa_link'] != null) _waLink = '${s['wa_link']}';
          if (s['business_number'] != null) _businessNumber = '${s['business_number']}';
        });
      }
    } catch (_) {
      // a missed poll is harmless: the next one in 3 seconds tries again
    } finally {
      _polling = false;
    }
  }

  void _startCooldown(int seconds, {bool initial = false}) {
    _cooldownTimer?.cancel();
    if (initial) {
      _cooldown = seconds;
    } else {
      setState(() => _cooldown = seconds);
    }
    if (seconds <= 0) return;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_cooldown <= 1) {
        t.cancel();
        setState(() => _cooldown = 0);
      } else {
        setState(() => _cooldown--);
      }
    });
  }

  // ------------------------------------------------------------------ actions

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

  Future<void> _resend(String channel) async {
    if (channel == 'template') {
      final ok = await confirm(
        context,
        'إرسال الرمز برسالة مدفوعة؟',
        'سيُرسل الرمز إلى واتساب المواطن${widget.phoneMasked.isEmpty ? '' : ' (${widget.phoneMasked})'} برسالة رسمية مدفوعة تُحتسب على الشركة. '
            'استخدمها فقط إذا لم يستطع المواطن مراسلة رقم الشركة.',
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await widget.onResend(channel);
      if (!mounted) return;
      _codeController.clear();
      _apply(code ?? {'state': 'sent', 'channel': channel == 'template' ? 'template' : null});
      if (mounted && _state == 'sent') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إرسال رمز جديد إلى واتساب المواطن'), backgroundColor: AppColors.info),
        );
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final entry = _useMaster || _state == 'sent';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!entry && _state == 'waiting') _waitingCard(),
        if (!entry && _state == 'expired') _expiredCard(),
        if (entry) ..._entry(),
        const SizedBox(height: Gap.sm),
        _masterSwitch(),
        if (_useMaster)
          TextField(
            controller: _reasonController,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'سبب استخدام الرمز الرئيسي (إلزامي)'),
          ),
        if (_error != null) NoticeBanner(title: _error!, tone: Tone.bad),
        if (entry) ...[
          const SizedBox(height: Gap.md),
          FilledButton(
            onPressed: _busy ? null : _verify,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : Text(widget.verifyLabel),
          ),
          if (!_useMaster)
            TextButton(
              onPressed: (_busy || _cooldown > 0) ? null : () => _resend('auto'),
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: Text(_cooldown > 0 ? 'إعادة الإرسال بعد $_cooldown ثانية' : 'إعادة إرسال الرمز'),
            ),
        ],
      ],
    );
  }

  List<Widget> _entry() {
    return [
      NoticeBanner(
        tone: _useMaster ? Tone.warn : Tone.good,
        icon: _useMaster ? Icons.key : Icons.mark_chat_read_outlined,
        title: _useMaster ? 'الرمز الرئيسي' : 'وصل الرمز إلى واتساب المواطن، اطلب منه قراءته لك',
        message: _useMaster
            ? 'أدخل الرمز الرئيسي الذي تبلغك به غرفة القيادة'
            : (widget.phoneMasked.isEmpty ? null : 'رقم المواطن: ${widget.phoneMasked}'),
        action: !_useMaster && _channel == 'free'
            ? const Chip(
                avatar: Icon(Icons.savings_outlined, size: 16, color: AppColors.good),
                label: Text('رسالة مجانية'),
                visualDensity: VisualDensity.compact,
              )
            : null,
      ),
      const SizedBox(height: Gap.md),
      TextField(
        controller: _codeController,
        keyboardType: TextInputType.number,
        maxLength: 6,
        textAlign: TextAlign.center,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontSize: 26, letterSpacing: 10, fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          labelText: _useMaster ? 'الرمز الرئيسي' : 'رمز المواطن (6 أرقام)',
          counterText: '',
        ),
      ),
    ];
  }

  String _clockText() {
    final s = _secondsLeft;
    if (s == null) return '';
    final v = s < 0 ? 0 : s;
    return '${(v ~/ 60).toString().padLeft(2, '0')}:${(v % 60).toString().padLeft(2, '0')}';
  }

  Widget _waitingCard() {
    final number = formatWhatsappNumber(_businessNumber);
    return AppCard(
      accent: AppColors.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(children: [
            Icon(Icons.forum_outlined, color: AppColors.info),
            SizedBox(width: Gap.sm),
            Expanded(
              child: Text('اطلب من المواطن إرسال رسالة واتساب',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.ink)),
            ),
          ]),
          const SizedBox(height: Gap.md),
          if (_waLink != null)
            Center(
              child: Container(
                padding: const EdgeInsets.all(Gap.sm),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(Gap.radiusSm),
                  border: Border.all(color: AppColors.border),
                ),
                child: QrImageView(data: _waLink!, size: 180, backgroundColor: Colors.white),
              ),
            ),
          if (number.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            const Text('رقم الشركة على واتساب', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Directionality(
                textDirection: TextDirection.ltr,
                child: SelectableText(
                  number,
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 1.5, color: AppColors.ink),
                ),
              ),
              IconButton(
                tooltip: 'نسخ الرقم',
                icon: const Icon(Icons.copy, size: 20),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: number.replaceAll(' ', '')));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم نسخ الرقم')));
                },
              ),
            ]),
          ],
          const SizedBox(height: Gap.sm),
          Text(
            _instructions ?? 'اطلب من المواطن إرسال اسمه برسالة واتساب إلى رقم الشركة (أو مسح الرمز)، وسيصله رمز التحقق فوراً.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: Gap.md),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Gap.sm),
            Text('بانتظار رسالة المواطن', style: const TextStyle(color: AppColors.muted)),
            if (_expiresAt != null) ...[
              const SizedBox(width: Gap.sm),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(_clockText(),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
              ),
            ],
          ]),
          const SizedBox(height: Gap.md),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _resend('template'),
            icon: const Icon(Icons.sms_outlined),
            label: const Text('المواطن لا يستطيع المراسلة: أرسل الرمز برسالة مدفوعة', textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  Widget _expiredCard() {
    return AppCard(
      accent: AppColors.warn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NoticeBanner(
            tone: Tone.warn,
            icon: Icons.timer_off_outlined,
            title: 'انتهت مدة الانتظار',
            message: 'لم تصل رسالة المواطن إلى رقم الشركة. يمكنك الانتظار مجدداً أو إرسال الرمز برسالة مدفوعة.',
          ),
          const SizedBox(height: Gap.sm),
          FilledButton.icon(
            onPressed: _busy ? null : () => _resend('auto'),
            icon: const Icon(Icons.refresh),
            label: const Text('الانتظار مجدداً'),
          ),
          const SizedBox(height: Gap.sm),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _resend('template'),
            icon: const Icon(Icons.sms_outlined),
            label: const Text('إرسال الرمز برسالة مدفوعة'),
          ),
        ],
      ),
    );
  }

  Widget _masterSwitch() {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: _useMaster,
      onChanged: _busy ? null : (v) => setState(() => _useMaster = v),
      title: const Text('المواطن لا يملك واتساب / لم يصل الرمز'),
      subtitle: const Text('استخدام الرمز الرئيسي من القيادة (يُسجَّل ويُراجَع)', style: TextStyle(fontSize: 12)),
    );
  }
}
