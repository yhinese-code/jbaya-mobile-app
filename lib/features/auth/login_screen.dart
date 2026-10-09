import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/device_identity.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../collector/collector_home.dart';
import '../command/command_screen.dart';
import '../finance/finance_portal_screen.dart';
import '../hr/hr_portal_screen.dart';
import '../owner/owner_portal_screen.dart';
import '../supervisor/supervisor_screen.dart';
import '../tech/tech_portal_screen.dart';

/// One login for every role. The server decides the role and (for collectors) the sector.
/// No WhatsApp codes for employees: a new phone / PC waits once for the tech panel's approval and is then bound
/// to this account. Sessions end every day at midnight (Baghdad time).
class LoginScreen extends StatefulWidget {
  /// Why the previous session ended (shown once), e.g. the daily logout or a session ended by the tech panel.
  final String? notice;
  const LoginScreen({super.key, this.notice});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;
  String? _notice; // why the previous session ended (shown until the next login attempt)

  // a new device waiting for the tech panel: retried automatically every 15 seconds
  String? _pending;
  Timer? _retry;
  String? _deviceId;
  bool _inFlight = false;   // the silent retry and the button must never log in twice at once

  @override
  void initState() {
    super.initState();
    _notice = widget.notice;
    DeviceIdentity.id().then((v) {
      if (mounted) setState(() => _deviceId = v);
    });
  }

  @override
  void dispose() {
    _retry?.cancel();
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login({bool silent = false}) async {
    if (_codeController.text.trim().isEmpty || _passwordController.text.isEmpty) {
      setState(() {
        _notice = null;
        _error = 'يرجى إدخال رقم الموظف وكلمة المرور';
      });
      return;
    }
    if (_inFlight) return;
    _inFlight = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
        _notice = null;
      });
    }
    try {
      final res = await ApiClient.instance.post('/auth/login', {
        'employee_code': _codeController.text.trim(),
        'password': _passwordController.text,
        'device_id': await DeviceIdentity.id(),
        'device_label': DeviceIdentity.label,
        'platform': DeviceIdentity.platform,
      });
      if (!mounted) return;
      if (res['device_pending'] == true) {
        setState(() => _pending = (res['message'] ?? 'بانتظار موافقة الإدارة التقنية').toString());
        _retry ??= Timer.periodic(const Duration(seconds: 15), (_) => _login(silent: true));
        return;
      }
      _retry?.cancel();
      _retry = null;
      _finish(res);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (silent && _pending != null && e.statusCode <= 0) return;   // no network for a moment: keep waiting
      _retry?.cancel();
      _retry = null;
      setState(() {
        _pending = null;
        _error = e.message;
      });
    } finally {
      _inFlight = false;
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  void _cancelPending() {
    _retry?.cancel();
    _retry = null;
    setState(() => _pending = null);
  }

  void _finish(dynamic res) {
    final user = Map<String, dynamic>.from(res['user'] as Map);
    Session.instance.start(res['token'] as String, user);
    _openPortal(user['role'] as String);
  }

  void _openPortal(String role) {
    Widget next;
    switch (role) {
      case 'collector':
        next = const CollectorHome();
        break;
      case 'supervisor':
        next = const SupervisorScreen();
        break;
      case 'finance':
        next = const FinancialPortalScreen();
        break;
      case 'hr':
        next = const HrPortalScreen();
        break;
      case 'owner':
        next = const OwnerPortalScreen();
        break;
      case 'command':
      case 'admin':
        next = const CentralCommandScreen();
        break;
      case 'tech':
        next = const TechPortalScreen();
        break;
      default:
        setState(() => _error = 'لا توجد بوابة لهذا الدور');
        return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => next));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Gap.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _brand(),
                  const SizedBox(height: Gap.xl),
                  Container(
                    padding: const EdgeInsets.all(Gap.xl),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(Gap.radius + 4),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _pending != null ? _pendingStep() : _form(),
                    ),
                  ),
                  if (_deviceId != null && _pending == null) ...[
                    const SizedBox(height: Gap.md),
                    Text('رمز هذا الجهاز: ${_deviceId!.substring(0, 12)}',
                        textAlign: TextAlign.center, style: const TextStyle(color: AppColors.faint, fontSize: 11)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brand() {
    return Column(children: [
      Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: AppColors.brand,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Icon(Icons.water_drop_outlined, size: 40, color: Colors.white),
      ),
      const SizedBox(height: Gap.md),
      const Text(
        'منظومة جباية بغداد',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink),
      ),
      const SizedBox(height: Gap.xs),
      const Text('تسجيل دخول الموظفين', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
    ]);
  }

  List<Widget> _form() {
    return [
      if (_notice != null) ...[
        NoticeBanner(tone: Tone.warn, icon: Icons.info_outline, title: 'انتهت الجلسة', message: _notice),
        const SizedBox(height: Gap.md),
      ],
      TextField(
        controller: _codeController,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'رقم الموظف (ID)',
          hintText: 'JB-0492',
          prefixIcon: Icon(Icons.badge_outlined),
        ),
      ),
      const SizedBox(height: Gap.lg),
      TextField(
        controller: _passwordController,
        obscureText: _obscure,
        onSubmitted: (_) => _login(),
        decoration: InputDecoration(
          labelText: 'كلمة المرور',
          prefixIcon: const Icon(Icons.lock_outline),
          suffixIcon: IconButton(
            tooltip: _obscure ? 'إظهار' : 'إخفاء',
            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: Gap.md),
        NoticeBanner(tone: Tone.bad, title: _error!),
      ],
      const SizedBox(height: Gap.xl),
      FilledButton(
        onPressed: _loading ? null : _login,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 16, fontWeight: FontWeight.w700),
        ),
        child: _loading
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Text('تسجيل الدخول'),
      ),
      const SizedBox(height: Gap.md),
      const Text(
        'يتم تحديد البوابة والقاطع تلقائياً حسب صلاحيات حسابك',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.muted, fontSize: 12),
      ),
    ];
  }

  List<Widget> _pendingStep() {
    final device = _deviceId == null ? '' : _deviceId!.substring(0, 12);
    return [
      NoticeBanner(
        tone: Tone.warn,
        icon: Icons.phonelink_lock,
        title: 'جهاز جديد بانتظار الاعتماد',
        message: _pending,
      ),
      const SizedBox(height: Gap.md),
      Text('أخبر الإدارة التقنية برقمك وبرمز الجهاز. سيتم الدخول تلقائياً بعد الموافقة.',
          style: const TextStyle(color: AppColors.muted)),
      const SizedBox(height: Gap.md),
      _idRow('رقم الموظف', _codeController.text.trim().toUpperCase()),
      _idRow('رمز الجهاز', device),
      const SizedBox(height: Gap.lg),
      const ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(4)),
        child: LinearProgressIndicator(minHeight: 4),
      ),
      const SizedBox(height: Gap.lg),
      FilledButton.icon(
        onPressed: _loading ? null : _login,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        icon: const Icon(Icons.refresh),
        label: const Text('تحقق الآن'),
      ),
      const SizedBox(height: Gap.xs),
      TextButton(
        onPressed: _cancelPending,
        style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: const Text('رجوع'),
      ),
    ];
  }

  Widget _idRow(String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.sm),
      padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
      decoration: BoxDecoration(
        color: AppColors.paper,
        borderRadius: BorderRadius.circular(Gap.radiusSm),
      ),
      child: Row(children: [
        Text(label, style: const TextStyle(color: AppColors.muted)),
        const Spacer(),
        Directionality(
          textDirection: TextDirection.ltr,
          child: SelectableText(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, letterSpacing: 1)),
        ),
      ]),
    );
  }
}
