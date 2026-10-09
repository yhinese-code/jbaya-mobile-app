import 'package:flutter/material.dart';

import '../../../core/format.dart';
import '../../../core/theme.dart';

/// Shows the receipt returned by POST /bills/{id}/verify. All amounts come from the server.
class ReceiptCard extends StatelessWidget {
  final Map<String, dynamic> receipt;
  final VoidCallback onDone;

  const ReceiptCard({super.key, required this.receipt, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final sent = receipt['receipt_whatsapp_sent'] == true;
    final viaMaster = receipt['verification_method'] == 'master_code';
    return AppCard(
      accent: AppColors.good,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle, size: 48, color: AppColors.good),
          const SizedBox(height: Gap.sm),
          Text('وصل رقم ${receipt['receipt_no']}',
              textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
          Text('${receipt['citizen_name']} - ${receipt['property_code']}',
              textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: Gap.sm),
          const Divider(),
          _row('رسوم الاستهلاك (للحكومة)', formatIqd(asNum(receipt['gov_amount']))),
          _row('أجور الجباية (للشركة)', formatIqd(asNum(receipt['company_fee']))),
          const Divider(),
          const SizedBox(height: Gap.sm),
          const Text('المبلغ المستلم', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
          Text(
            formatIqd(asNum(receipt['total_amount'])),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, color: AppColors.good),
          ),
          const SizedBox(height: Gap.sm),
          NoticeBanner(
            tone: sent ? Tone.good : Tone.warn,
            icon: sent ? Icons.mark_chat_read_outlined : Icons.sms_failed_outlined,
            title: sent ? 'تم إرسال الوصل إلى واتساب المواطن' : 'تم تسجيل الدفع، لكن تعذر إرسال الوصل عبر واتساب (سيُعاد لاحقاً)',
          ),
          if (viaMaster)
            const NoticeBanner(tone: Tone.warn, icon: Icons.key_outlined, title: 'تم التأكيد بالرمز الرئيسي - العملية مسجلة للمراجعة'),
          const SizedBox(height: Gap.md),
          FilledButton(
            onPressed: onDone,
            style: FilledButton.styleFrom(backgroundColor: AppColors.good, minimumSize: const Size.fromHeight(52)),
            child: const Text('إنهاء'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppColors.muted)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
