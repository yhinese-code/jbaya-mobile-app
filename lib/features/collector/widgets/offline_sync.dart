import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../core/offline_queue.dart';
import '../../../core/theme.dart';
import '../../shared/ui.dart' show confirm;

/// AppBar button: a cloud icon with the number of items waiting on the phone. Mobile only (nothing on the web).
class OfflineSyncButton extends StatelessWidget {
  const OfflineSyncButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!OfflineQueue.supported) return const SizedBox.shrink();
    final q = OfflineQueue.instance;
    return ListenableBuilder(
      listenable: q,
      builder: (context, _) {
        final count = q.pendingCount + q.failedCount;
        final icon = q.syncing
            ? Icons.cloud_sync_outlined
            : (q.offline ? Icons.cloud_off : (count > 0 ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined));
        return IconButton(
          tooltip: q.offline ? 'دون اتصال - العمل المحفوظ على الهاتف' : 'المزامنة',
          onPressed: () => showOfflineQueueSheet(context),
          icon: Badge(
            isLabelVisible: count > 0,
            backgroundColor: q.failedCount > 0 ? AppColors.bad : AppColors.warn,
            label: Text('$count'),
            child: Icon(icon),
          ),
        );
      },
    );
  }
}

/// A thin strip under the summary: shown only when offline or when work is waiting on the phone.
class OfflineStrip extends StatefulWidget {
  const OfflineStrip({super.key});

  @override
  State<OfflineStrip> createState() => _OfflineStripState();
}

class _OfflineStripState extends State<OfflineStrip> {
  @override
  void initState() {
    super.initState();
    if (OfflineQueue.supported) OfflineQueue.instance.init();
  }

  @override
  Widget build(BuildContext context) {
    if (!OfflineQueue.supported) return const SizedBox.shrink();
    final q = OfflineQueue.instance;
    return ListenableBuilder(
      listenable: q,
      builder: (context, _) {
        final waiting = q.pendingCount;
        final failed = q.failedCount;
        if (!q.offline && waiting == 0 && failed == 0) return const SizedBox.shrink();
        final tone = failed > 0 ? Tone.bad : (q.offline ? Tone.warn : Tone.info);
        final c = toneColor(tone);
        final parts = <String>[
          if (q.offline) 'دون اتصال',
          if (waiting > 0) '$waiting بانتظار المزامنة',
          if (failed > 0) '$failed مرفوض',
        ];
        return Material(
          color: c.withValues(alpha: 0.08),
          child: InkWell(
            onTap: () => showOfflineQueueSheet(context),
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Row(children: [
                q.syncing
                    ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: c))
                    : Icon(q.offline ? Icons.cloud_off : Icons.cloud_upload_outlined, color: c, size: 20),
                const SizedBox(width: Gap.sm),
                Expanded(child: Text(parts.join('  ·  '), style: TextStyle(color: c, fontWeight: FontWeight.w600))),
                if (waiting > 0 && !q.syncing)
                  TextButton(onPressed: () => _syncNow(context), child: const Text('مزامنة الآن'))
                else
                  Icon(Icons.chevron_left, color: c),
              ]),
            ),
          ),
        );
      },
    );
  }
}

Future<void> _syncNow(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final r = await OfflineQueue.instance.sync();
  if (r.error != null) {
    messenger.showSnackBar(SnackBar(content: Text(r.error!), backgroundColor: AppColors.bad));
  } else if (r.synced > 0 || r.failed > 0) {
    messenger.showSnackBar(SnackBar(
      content: Text('تمت مزامنة ${r.synced}${r.failed > 0 ? '، ورُفض ${r.failed}' : ''}'),
      backgroundColor: r.failed > 0 ? AppColors.warn : AppColors.good,
    ));
  }
}

/// Bottom sheet: everything saved on the phone, its status and the server's answer, plus "sync now".
Future<void> showOfflineQueueSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.paper,
    builder: (_) => const _QueueSheet(),
  );
}

class _QueueSheet extends StatefulWidget {
  const _QueueSheet();

  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  final _q = OfflineQueue.instance;
  List<OfflineItem>? _items;

  @override
  void initState() {
    super.initState();
    _q.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _q.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    List<OfflineItem> items;
    try {
      items = await _q.list();
    } catch (_) {
      items = const [];
    }
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (context, scroll) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Row(children: [
              const Expanded(
                child: Text('العمل المحفوظ على الهاتف', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              Text(_q.offline ? 'دون اتصال' : 'متصل',
                  style: TextStyle(color: _q.offline ? AppColors.warn : AppColors.good, fontWeight: FontWeight.w600)),
            ]),
          ),
          if (_q.lastSyncError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: NoticeBanner(tone: Tone.warn, title: 'تعذرت المزامنة', message: _q.lastSyncError),
            ),
          Expanded(
            child: items == null
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? const EmptyState(
                        icon: Icons.cloud_done_outlined,
                        title: 'لا يوجد عمل بانتظار المزامنة',
                        message: 'عند انقطاع الإنترنت يمكنك حفظ التسجيلات والقراءات هنا، وتُرسل تلقائياً عند عودة الاتصال.',
                      )
                    : ListView.builder(
                        controller: scroll,
                        padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.xs),
                        itemCount: items.length,
                        itemBuilder: (_, i) => _tile(items[i]),
                      ),
          ),
          Container(
            decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: AppColors.border))),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(Gap.lg),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: _q.syncing || _q.pendingCount == 0 ? null : () => _syncNow(context),
                  icon: _q.syncing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.sync),
                  label: Text(_q.pendingCount == 0 ? 'لا يوجد ما يُزامن' : 'مزامنة الآن (${_q.pendingCount})'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(OfflineItem it) {
    final tone = it.status == 'synced' ? Tone.good : (it.status == 'failed' ? Tone.bad : Tone.warn);
    final c = toneColor(tone);
    final statusLabel = it.status == 'synced' ? 'تمت المزامنة' : (it.status == 'failed' ? 'مرفوض' : 'بانتظار المزامنة');
    final r = it.result;
    String? outcome;
    if (it.status == 'synced' && r != null) {
      outcome = it.isRegistration
          ? 'العقار ${r['property_code'] ?? ''}: يتفعّل برسالة المواطن إلى رقم الشركة أو برمز في الزيارة القادمة'
          : 'فاتورة ${r['property_code'] ?? ''}'
              '${r['total_amount'] != null ? ' بمبلغ ${formatIqd(asNum(r['total_amount']))}' : ''}'
              '${r['status'] == 'pending_approval' ? ' (بانتظار موافقة المشرف)' : ' تُستلم في الزيارة القادمة'}';
    }
    return AppCard(
      accent: c,
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(it.isRegistration ? Icons.person_add_alt_1 : Icons.speed, size: 20, color: AppColors.muted),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(it.isRegistration ? 'تسجيل عقار' : 'قراءة عداد',
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          Text(statusLabel, style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12)),
        ]),
        const SizedBox(height: Gap.xs),
        Text(it.label),
        Text('سُجّل ${formatDate(it.capturedAt)} ${formatTime(it.capturedAt)}',
            style: const TextStyle(fontSize: 12, color: AppColors.muted)),
        if (outcome != null) ...[
          const SizedBox(height: Gap.xs),
          Text(outcome, style: const TextStyle(fontSize: 13, color: AppColors.good)),
        ],
        if (it.error != null && it.status != 'synced') ...[
          const SizedBox(height: Gap.xs),
          Text(it.error!, style: TextStyle(fontSize: 13, color: it.status == 'failed' ? AppColors.bad : AppColors.warn)),
        ],
        if (it.status == 'failed')
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: () async {
                final ok = await confirm(context, 'حذف من الهاتف؟',
                    'رفض الخادم هذا العمل ولن يُرسل مجدداً. احذفه بعد معالجة السبب (مثلاً بإعادة التسجيل أو القراءة).');
                if (ok) await _q.remove(it.id);
              },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('حذف من الهاتف'),
              style: TextButton.styleFrom(foregroundColor: AppColors.bad, minimumSize: const Size(48, 44)),
            ),
          ),
      ]),
    );
  }
}
