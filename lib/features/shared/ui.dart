import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/theme.dart';

/// Small coloured pill for statuses.
class StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const StatusChip(this.label, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600, height: 1.4)),
    );
  }
}

/// Status word -> tone colour from the app palette (same mapping as core/format.dart statusColor,
/// but with the design-system colours; 'leave' reads as info rather than warning).
Color statusTone(String? s) {
  switch (s) {
    case 'approved':
    case 'paid':
    case 'completed':
    case 'present':
    case 'returned':
      return toneColor(Tone.good);
    case 'rejected':
    case 'absent':
    case 'lost':
      return toneColor(Tone.bad);
    case 'cancelled':
    case 'weekend':
      return toneColor(Tone.neutral);
    case 'leave':
      return toneColor(Tone.info);
    default:
      return toneColor(Tone.warn);
  }
}

/// Tab bar for a portal AppBar (white indicator, readable white labels). Same look as PermittedTabs.
TabBar portalTabBar(List<Widget> tabs) => TabBar(
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelColor: Colors.white,
      unselectedLabelColor: Colors.white.withValues(alpha: 0.78),
      indicatorColor: Colors.white,
      indicatorWeight: 3,
      indicatorSize: TabBarIndicatorSize.label,
      labelStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontWeight: FontWeight.w700, fontSize: 14),
      unselectedLabelStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontWeight: FontWeight.w500, fontSize: 14),
      labelPadding: const EdgeInsets.symmetric(horizontal: Gap.md),
      dividerColor: Colors.transparent,
      tabs: tabs,
    );

class SectionTitle extends StatelessWidget {
  final String text;
  final List<Widget> actions;
  const SectionTitle(this.text, {super.key, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Gap.lg, bottom: Gap.sm),
      child: Row(
        children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.ink))),
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
      messenger.showSnackBar(SnackBar(content: Text(success), backgroundColor: AppColors.good));
    }
    return r;
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppColors.bad));
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
      return EmptyState(
        icon: Icons.cloud_off,
        title: 'تعذر تحميل البيانات',
        message: _error,
        action: OutlinedButton.icon(onPressed: reload, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
      );
    }
    return widget.builder(context, _data, reload);
  }
}
