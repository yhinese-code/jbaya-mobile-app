import 'package:flutter/material.dart';

import '../../core/api_client.dart';

/// Small coloured pill for statuses.
class StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const StatusChip(this.label, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final List<Widget> actions;
  const SectionTitle(this.text, {super.key, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
          ...actions,
        ],
      ),
    );
  }
}

/// Runs an API call and shows the server's Arabic error (or [success]) in a snackbar. Returns the result or null.
Future<T?> runApi<T>(BuildContext context, Future<T> Function() call, {String? success}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final r = await call();
    if (success != null) {
      messenger.showSnackBar(SnackBar(content: Text(success), backgroundColor: Colors.green.shade700));
    }
    return r;
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: Colors.red.shade700));
    return null;
  }
}

/// Asks for a note. Returns null when cancelled; '' allowed only when [required] is false.
Future<String?> askNote(BuildContext context, String title, {bool required = false, String label = 'الملاحظة'}) async {
  final c = TextEditingController();
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: required ? '$label (إلزامي)' : '$label (اختياري)',
            border: const OutlineInputBorder(),
            errorText: error,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () {
              if (required && c.text.trim().length < 3) {
                setD(() => error = 'يرجى الكتابة');
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('تأكيد'),
          ),
        ],
      ),
    ),
  );
  final text = c.text.trim();
  Future.delayed(const Duration(milliseconds: 400), c.dispose);
  return ok == true ? text : null;
}

/// Simple two-option confirm.
Future<bool> confirm(BuildContext context, String title, String message) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تأكيد')),
      ],
    ),
  );
  return ok == true;
}

/// Loads a JSON list/map, shows a spinner, an error with retry, or [builder].
class ApiView extends StatefulWidget {
  final String path;
  final Widget Function(BuildContext context, dynamic data, Future<void> Function() reload) builder;
  const ApiView({super.key, required this.path, required this.builder});

  @override
  State<ApiView> createState() => ApiViewState();
}

class ApiViewState extends State<ApiView> {
  dynamic _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void didUpdateWidget(covariant ApiView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _data = null; // never show the previous path's data under the new filter
      reload();
    }
  }

  Future<void> reload() async {
    if (!mounted) return;
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final d = await ApiClient.instance.get(widget.path);
      if (mounted) setState(() => _data = d);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _data == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            TextButton(onPressed: reload, child: const Text('إعادة المحاولة')),
          ],
        ),
      );
    }
    return widget.builder(context, _data, reload);
  }
}
