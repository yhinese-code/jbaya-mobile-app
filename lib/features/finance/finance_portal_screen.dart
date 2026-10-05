import 'package:flutter/material.dart';

import '../../core/session.dart';

// Finance portal: still demo numbers. Real ledger, charts and analytics arrive in Phase 4.
// --- 7. SEPARATE FINANCIAL PORTAL SCREEN ---
class FinancialPortalScreen extends StatelessWidget {
  const FinancialPortalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('البوابة المالية المركزية (إيرادات وتحصيلات)', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.green.shade800,
        foregroundColor: Colors.white,
        actions: const [LogoutButton()],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('الملخص المالي الشامل للمنظومة', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF1B3B6F))),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(child: _buildFinCard('إجمالي الجباية المحصلة', '45,500,000 د.ع', Colors.green, Icons.attach_money)),
                const SizedBox(width: 16),
                Expanded(child: _buildFinCard('حصة خزينة الدولة', '41,500,000 د.ع', Colors.blueGrey, Icons.account_balance)),
                const SizedBox(width: 16),
                Expanded(child: _buildFinCard('إيرادات الشركة الأهلية', '4,000,000 د.ع', Colors.teal, Icons.business)),
                const SizedBox(width: 16),
                Expanded(child: _buildFinCard('إجمالي المتأخرات والديون', '12,300,000 د.ع', Colors.red, Icons.money_off)),
              ],
            ),
            const SizedBox(height: 32),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('توزيع التدفقات النقدية وحسابات الخزينة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const Divider(height: 24),
                    const ListTile(
                      leading: Icon(Icons.check_circle, color: Colors.green),
                      title: Text('حساب الخزينة العامة (أمانة بغداد)'),
                      subtitle: Text('تحديث مباشر عبر بوابات التسوية النقدية للمشرفين'),
                      trailing: Text('41,500,000 د.ع', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                    const Divider(),
                    const ListTile(
                      leading: Icon(Icons.business_center, color: Colors.teal),
                      title: Text('صندوق التشغيل وأجور الشركة (3,000 دينار لكل وصل)'),
                      subtitle: Text('مخصص لدعم التشغيل وأجهزة القراءة'),
                      trailing: Text('4,000,000 د.ع', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ],
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildFinCard(String title, String value, Color color, IconData icon) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey))),
                Icon(icon, color: color, size: 26),
              ],
            ),
            const SizedBox(height: 12),
            Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }
}
