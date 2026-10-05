import 'package:flutter/material.dart';

import 'core/api_client.dart';

// Legacy analytics screen from the prototype (reads /analytics/summary). Not linked from the menus yet.

class SupervisorDashboardScreen extends StatefulWidget {
  const SupervisorDashboardScreen({super.key});

  @override
  State<SupervisorDashboardScreen> createState() => _SupervisorDashboardScreenState();
}

class _SupervisorDashboardScreenState extends State<SupervisorDashboardScreen> {
  Map<String, dynamic> _analyticsData = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchAnalytics();
  }

  Future<void> _fetchAnalytics() async {
    try {
      final res = await ApiClient.instance.get('/analytics/summary');
      setState(() {
        _analyticsData = Map<String, dynamic>.from(res as Map);
        _isLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('لوحة تحكم المشرفين والتحليلات المركزية'),
        backgroundColor: const Color(0xFF004D40),
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('مؤشرات الأداء الميداني (أمانة بغداد)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildMetricCard('إجمالي الدور المنجزة', '${_analyticsData['total_properties_serviced'] ?? 0}', Colors.blue),
                      _buildMetricCard('مسارات الدفع المؤكد', '${_analyticsData['path_breakdown']?['verified_paid']?['count'] ?? 0}', Colors.green),
                      _buildMetricCard('إشعارات الغياب والجار', '${_analyticsData['path_breakdown']?['absent_notice_left']?['count'] ?? 0}', Colors.orange),
                    ],
                  ),
                  const SizedBox(height: 30),
                  const Divider(),
                  const SizedBox(height: 20),
                  const Text('حالة المزامنة والتدقيق اللحظي', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView(
                      children: const [
                        ListTile(
                          leading: Icon(Icons.verified, color: Colors.green),
                          title: Text('محلة 653 - قاطع حي الجامعة'),
                          subtitle: Text('تمت مزامنة 30 سجل بنجاح دون أي تناقضات مالية'),
                          trailing: Text('مكتمل', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                        ),
                        ListTile(
                          leading: Icon(Icons.warning, color: Colors.orange),
                          title: Text('محلة 609 - قاطع المنصور'),
                          subtitle: Text('4 دور مسجلة ضمن مسار "الجار القريب" (إشعارات معلقة)'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildMetricCard(String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.4)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8)],
      ),
      child: Column(
        children: [
          Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 8),
          Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }
}