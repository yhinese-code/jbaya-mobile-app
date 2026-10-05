import 'package:flutter/material.dart';

import '../../../core/format.dart';

/// Shows the receipt returned by POST /bills/{id}/verify. All amounts come from the server.
class ReceiptCard extends StatelessWidget {
  final Map<String, dynamic> receipt;
  final VoidCallback onDone;

  const ReceiptCard({super.key, required this.receipt, required this.onDone});

  @override
  Widget build(BuildContext context) {
    final sent = receipt['receipt_whatsapp_sent'] == true;
    final viaMaster = receipt['verification_method'] == 'master_code';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        border: Border.all(color: Colors.green),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          const Icon(Icons.receipt_long, size: 40, color: Colors.green),
          Text('وصل رقم ${receipt['receipt_no']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          Text('${receipt['citizen_name']} - ${receipt['property_code']}'),
          const Divider(),
          _row('رسوم الاستهلاك (للحكومة)', formatIqd(asNum(receipt['gov_amount']))),
          _row('أجور الجباية (للشركة)', formatIqd(asNum(receipt['company_fee']))),
          const SizedBox(height: 8),
          Text(
            'المبلغ المستلم: ${formatIqd(asNum(receipt['total_amount']))}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            width: double.infinity,
            color: sent ? Colors.green.shade100 : Colors.orange.shade100,
            child: Text(
              sent ? 'تم إرسال الوصل إلى واتساب المواطن' : 'تم تسجيل الدفع، لكن تعذر إرسال الوصل عبر واتساب (سيُعاد لاحقاً)',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          if (viaMaster)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('تم التأكيد بالرمز الرئيسي - العملية مسجلة للمراجعة',
                  style: TextStyle(color: Colors.orange.shade900, fontSize: 12)),
            ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: onDone,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 50),
            ),
            child: const Text('إنهاء'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label), Text(value, style: const TextStyle(fontWeight: FontWeight.bold))],
      ),
    );
  }
}
