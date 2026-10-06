import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../collector/collector_home.dart';
import '../command/command_screen.dart';
import '../finance/finance_portal_screen.dart';
import '../supervisor/supervisor_screen.dart';

/// One login for every role. The server decides the role and (for collectors) the sector.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  // two-factor step (Command / admin): code sent to the employee's own WhatsApp
  Map<String, dynamic>? _challenge;
  final _codeInput = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    _passwordController.dispose();
    _codeInput.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_codeController.text.trim().isEmpty || _passwordController.text.isEmpty) {
      setState(() => _error = 'يرجى إدخال رقم الموظف وكلمة المرور');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.post('/auth/login', {
        'employee_code': _codeController.text.trim(),
        'password': _passwordController.text,
      });
      if (!mounted) return;
      if (res['two_factor_required'] == true) {
        setState(() => _challenge = Map<String, dynamic>.from(res as Map));
        return;
      }
      _finish(res);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _finish(dynamic res) {
    final user = Map<String, dynamic>.from(res['user'] as Map);
    Session.instance.start(res['token'] as String, user);
    _openPortal(user['role'] as String);
  }

  Future<void> _verifyCode() async {
    if (_codeInput.text.trim().length < 4) {
      setState(() => _error = 'يرجى إدخال الرمز');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.post('/auth/verify-2fa', {
        'challenge_id': _challenge!['challenge_id'],
        'code': _codeInput.text.trim(),
      });
      if (!mounted) return;
      _finish(res);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        // the server cancels the challenge after too many attempts or on expiry: start again
        if (e.message.contains('من جديد')) {
          _challenge = null;
          _codeInput.clear();
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
      case 'command':
      case 'admin':
        next = const CentralCommandScreen();
        break;
      default:
        setState(() => _error = 'بوابة هذا الدور قيد التطوير (الموارد البشرية - المرحلة 3)');
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
                if (_challenge != null) ..._twoFactorStep() else ...[
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
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _twoFactorStep() {
    return [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1B3B6F).withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF1B3B6F).withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.verified_user, color: Color(0xFF1B3B6F)),
            const SizedBox(width: 10),
            Expanded(
              child: Text('تحقق بخطوتين: أرسلنا رمزاً إلى واتساب ${_challenge!['phone_masked']}'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _codeInput,
        autofocus: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        textAlign: TextAlign.center,
        onSubmitted: (_) => _verifyCode(),
        style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
        decoration: const InputDecoration(labelText: 'رمز التحقق', border: OutlineInputBorder(), counterText: ''),
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
      ],
      const SizedBox(height: 16),
      ElevatedButton(
        onPressed: _loading ? null : _verifyCode,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          backgroundColor: const Color(0xFF1B3B6F),
          foregroundColor: Colors.white,
        ),
        child: _loading
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : const Text('تأكيد الدخول', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ),
      TextButton(
        onPressed: _loading
            ? null
            : () => setState(() {
                  _challenge = null;
                  _codeInput.clear();
                  _error = null;
                }),
        child: const Text('رجوع'),
      ),
    ];
  }
}
