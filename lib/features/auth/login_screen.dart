import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/device_identity.dart';
import '../../core/session.dart';
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

  // a new device waiting for the tech panel: retried automatically every 15 seconds
  String? _pending;
  Timer? _retry;
  String? _deviceId;
  bool _inFlight = false;   // the silent retry and the button must never log in twice at once

  @override
  void initState() {
    super.initState();
    _error = widget.notice;
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
      setState(() => _error = 'يرجى إدخال رقم الموظف وكلمة المرور');
      return;
    }
    if (_inFlight) return;
    _inFlight = true;
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
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
      if (silent && _pending != null && e.statusCode == 0) return;   // no network for a moment: keep waiting
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
      backgroundColor: const Color(0xFFE8ECEF),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 440),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 12)],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.map, size: 50, color: Color(0xFF004D40)),
                const SizedBox(height: 16),
                const Text(
                  'منظومة جباية بغداد المركزية',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF004D40)),
                ),
                const SizedBox(height: 24),
                if (_pending != null) ..._pendingStep() else ...[
                TextField(
                  controller: _codeController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'رقم الموظف (ID)',
                    hintText: 'JB-0492',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.badge),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscure,
                  onSubmitted: (_) => _login(),
                  decoration: InputDecoration(
                    labelText: 'كلمة المرور',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _loading ? null : _login,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: const Color(0xFF004D40),
                    foregroundColor: Colors.white,
                  ),
                  child: _loading
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('تسجيل الدخول', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 10),
                const Text(
                  'يتم تحديد البوابة والقاطع تلقائياً حسب صلاحيات حسابك',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                if (_deviceId != null) ...[
                  const SizedBox(height: 6),
                  Text('رمز هذا الجهاز: ${_deviceId!.substring(0, 12)}',
                      textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 11)),
                ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _pendingStep() {
    return [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.amber.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.amber.shade700),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.phonelink_lock, color: Colors.amber.shade900),
              const SizedBox(width: 8),
              const Expanded(child: Text('جهاز جديد بانتظار الاعتماد', style: TextStyle(fontWeight: FontWeight.bold))),
            ]),
            const SizedBox(height: 8),
            Text(_pending!),
            const SizedBox(height: 8),
            Text('أخبر الإدارة التقنية برقمك ${_codeController.text.trim().toUpperCase()} '
                'ورمز الجهاز ${_deviceId == null ? '' : _deviceId!.substring(0, 12)}. '
                'سيتم الدخول تلقائياً بعد الموافقة.', style: const TextStyle(fontSize: 13)),
          ],
        ),
      ),
      const SizedBox(height: 16),
      const LinearProgressIndicator(),
      const SizedBox(height: 16),
      ElevatedButton.icon(
        onPressed: _loading ? null : _login,
        icon: const Icon(Icons.refresh),
        label: const Text('تحقق الآن'),
      ),
      TextButton(onPressed: _cancelPending, child: const Text('رجوع')),
    ];
  }
}
