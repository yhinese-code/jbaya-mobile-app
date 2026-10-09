import 'package:flutter/material.dart';

import '../../../core/api_client.dart';
import '../../../core/location_service.dart';
import '../../../core/theme.dart';

/// Panic button. Asks for confirmation (to avoid pocket presses), then sends the alert
/// even if GPS fails, so help is never blocked by a bad location fix.
class SosButton extends StatelessWidget {
  final VoidCallback? onSent;
  const SosButton({super.key, this.onSent});

  Future<void> _send(BuildContext context) async {
    final noteController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: AppColors.bad, size: 40),
        title: const Text('إرسال نداء استغاثة؟'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('سيصل موقعك فوراً إلى المشرف وغرفة القيادة.'),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.bad, foregroundColor: Colors.white),
            child: const Text('إرسال الاستغاثة'),
          ),
        ],
      ),
    );
    final note = noteController.text.trim();
    Future.delayed(const Duration(milliseconds: 400), noteController.dispose); // after the dialog's exit animation
    if (ok != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(content: Text('جاري إرسال الاستغاثة...'), duration: Duration(seconds: 2)));

    GpsFix? gps;
    try {
      gps = await LocationService.current().timeout(const Duration(seconds: 10));
    } catch (_) {
      gps = null; // send anyway
    }
    try {
      await ApiClient.instance.post('/sos', {
        'lat': gps?.lat,
        'lng': gps?.lng,
        'gps_accuracy_m': gps?.accuracy,
        'note': note.isEmpty ? null : note,
      });
      messenger.showSnackBar(const SnackBar(
        content: Text('تم إرسال نداء الاستغاثة إلى المشرف والقيادة'),
        backgroundColor: AppColors.bad,
        duration: Duration(seconds: 6),
      ));
      onSent?.call();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('فشل الإرسال: ${e.message}. اتصل بالمشرف هاتفياً فوراً'),
        backgroundColor: AppColors.bad,
        duration: const Duration(seconds: 10),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: ElevatedButton.icon(
        onPressed: () => _send(context),
        icon: const Icon(Icons.sos, size: 18),
        label: const Text('استغاثة'),
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.bad,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 40),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          side: const BorderSide(color: Colors.white70),
        ),
      ),
    );
  }
}
