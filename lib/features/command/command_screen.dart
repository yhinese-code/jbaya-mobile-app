import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/session.dart';
import 'master_code_tab.dart';

// Central Command. Map, analytics, receipts and messages tabs are still demo data (real versions in Phase 2).
// The master code tab is live.
class CentralCommandScreen extends StatefulWidget {
  const CentralCommandScreen({super.key});
  @override
  State<CentralCommandScreen> createState() => _CentralCommandScreenState();
}

class _CentralCommandScreenState extends State<CentralCommandScreen> {
  int _selectedTabIndex = 0;
  final MapController _mapController = MapController();
  final TextEditingController _pingController = TextEditingController();
  
  final List<Map<String, dynamic>> _houses = List.generate(40, (index) {
    int days = index % 3 == 0 ? (65 + Random().nextInt(40)) : (index % 2 == 0 ? (30 + Random().nextInt(25)) : Random().nextInt(25));
    Color statusColor = days >= 60 ? Colors.red : (days >= 29 ? Colors.orange : Colors.green);
    double prevRead = 1000.0 + Random().nextInt(500);
    double usage = 20.0 + Random().nextInt(80);
    return {
      'id': 'Dar-${index + 100}',
      'location': LatLng(33.3152 + (Random().nextDouble() - 0.5) * 0.05, 44.3661 + (Random().nextDouble() - 0.5) * 0.05),
      'status': statusColor,
      'days_overdue': days,
      'owner': 'مواطن $index',
      'prev_read': prevRead,
      'current_read': prevRead + usage,
      'usage': usage,
      'fee_collected': (usage * 100) + 3000,
    };
  });

  final List<Map<String, dynamic>> _agents = List.generate(250, (index) {
    bool isSupervisor = index % 10 == 0;
    return {
      'id': isSupervisor ? 'SP-${index+1}' : 'JB-0${index+1}2',
      'name': isSupervisor ? 'مشرف: أحمد قاسم' : 'جابي: موظف ${index + 1}',
      'role': isSupervisor ? 'مشرف' : 'جابي',
      'location': LatLng(33.3152 + (Random().nextDouble() - 0.5) * 0.04, 44.3661 + (Random().nextDouble() - 0.5) * 0.04),
      'amount': isSupervisor ? 0 : (200000 + Random().nextInt(300000)),
      'visits': isSupervisor ? 0 : (10 + Random().nextInt(30)),
    };
  });

  final List<Map<String, dynamic>> _receiptLogs = List.generate(50, (index) {
    double total = (10000.0 + Random().nextInt(40000));
    return {
      'rcpt_id': 'RCP-${89230 + index}',
      'time': '${10 + Random().nextInt(12)}:${Random().nextInt(59).toString().padLeft(2, '0')}',
      'agent': 'JB-0${Random().nextInt(250)}2',
      'property': 'Dar-${100 + Random().nextInt(500)}',
      'total': total,
      'gov_share': total - 3000,
      'company_share': 3000,
      'status': index % 15 == 0 ? 'مراجعة (Mismatch)' : 'مكتمل (OTP)',
    };
  });

  Map<String, dynamic>? _selectedHouse;
  Map<String, dynamic>? _selectedAgentForMap;
  Timer? _movementTimer;

  @override
  void initState() {
    super.initState();
    _movementTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_selectedTabIndex == 0) {
        setState(() {
          for (var agent in _agents.take(15)) {
            double currentLat = agent['location'].latitude;
            double currentLon = agent['location'].longitude;
            agent['location'] = LatLng(currentLat + (Random().nextDouble() - 0.5) * 0.0005, currentLon + (Random().nextDouble() - 0.5) * 0.0005);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _movementTimer?.cancel();
    _pingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F4F8),
      appBar: AppBar(
        title: const Text('القيادة المركزية ERP - منظومة جباية بغداد', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1B3B6F),
        foregroundColor: Colors.white,
        actions: const [LogoutButton()],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedTabIndex,
            onDestinationSelected: (int index) => setState(() => _selectedTabIndex = index),
            labelType: NavigationRailLabelType.all,
            backgroundColor: Colors.white,
            selectedIconTheme: const IconThemeData(color: Color(0xFF1B3B6F)),
            selectedLabelTextStyle: const TextStyle(color: Color(0xFF1B3B6F), fontWeight: FontWeight.bold),
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: Text('العمليات الحية')),
              NavigationRailDestination(icon: Icon(Icons.analytics_outlined), selectedIcon: Icon(Icons.analytics), label: Text('التحليل الإداري')),
              NavigationRailDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: Text('سجل الإيصالات')),
              NavigationRailDestination(icon: Icon(Icons.message_outlined), selectedIcon: Icon(Icons.message), label: Text('الرسائل (Ping)')),
              NavigationRailDestination(icon: Icon(Icons.key_outlined), selectedIcon: Icon(Icons.key), label: Text('الرمز الرئيسي')),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: _buildSelectedTab(),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedTab() {
    switch (_selectedTabIndex) {
      case 0: return _buildLiveMapTab();
      case 1: return _buildAnalyticsTab();
      case 2: return _buildReceiptLogsTab();
      case 3: return _buildMessagesTab();
      case 4: return const MasterCodeTab();
      default: return const Center(child: Text('قريباً...'));
    }
  }

  // --- TAB 1: LIVE MAP ---
  Widget _buildLiveMapTab() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 5,
          child: Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8)]),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: const MapOptions(initialCenter: LatLng(33.3152, 44.3661), initialZoom: 14.0),
                    children: [
                      TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.jbaya.prototype'),
                      MarkerLayer(
                        markers: [
                          ..._houses.map((h) => Marker(
                            point: h['location'],
                            width: 32,
                            height: 32,
                            child: GestureDetector(
                              onTap: () => setState(() { _selectedHouse = h; _selectedAgentForMap = null; }),
                              child: Container(decoration: BoxDecoration(color: h['status'].withOpacity(0.5), border: Border.all(color: h['status'], width: 2.5), borderRadius: BorderRadius.circular(4))),
                            ),
                          )),
                          ..._agents.take(15).map((a) => Marker(
                            point: a['location'],
                            width: 50,
                            height: 50,
                            child: GestureDetector(
                              onTap: () => setState(() { _selectedAgentForMap = a; _selectedHouse = null; }),
                              child: Column(
                                children: [
                                  Icon(a['role'] == 'مشرف' ? Icons.security : Icons.person_pin_circle, color: a['role'] == 'مشرف' ? Colors.orange : Colors.blue, size: 30),
                                  Container(padding: const EdgeInsets.all(2), color: Colors.white, child: Text(a['id'], style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold))),
                                ],
                              ),
                            ),
                          ))
                        ],
                      ),
                    ],
                  ),
                  Positioned(bottom: 20, left: 20, child: Column(children: [
                    FloatingActionButton(mini: true, heroTag: "btn1", backgroundColor: Colors.white, onPressed: () => _mapController.move(_mapController.camera.center, _mapController.camera.zoom + 1), child: const Icon(Icons.add, color: Color(0xFF1B3B6F))),
                    const SizedBox(height: 8),
                    FloatingActionButton(mini: true, heroTag: "btn2", backgroundColor: Colors.white, onPressed: () => _mapController.move(_mapController.camera.center, _mapController.camera.zoom - 1), child: const Icon(Icons.remove, color: Color(0xFF1B3B6F))),
                  ])),
                  if (_selectedHouse != null)
                    Positioned(
                      top: 20, right: 20,
                      child: Card(
                        elevation: 8,
                        child: Container(
                          width: 300, padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                Text('عقار: ${_selectedHouse!['id']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => setState(() => _selectedHouse = null), padding: EdgeInsets.zero, constraints: const BoxConstraints())
                              ]),
                              const Divider(),
                              Text('المالك: ${_selectedHouse!['owner']}'),
                              Text('أيام التأخير: ${_selectedHouse!['days_overdue']} يوم', style: TextStyle(color: _selectedHouse!['status'], fontWeight: FontWeight.bold)),
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(8), color: Colors.grey.shade100,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('القراءة السابقة: ${_selectedHouse!['prev_read'].toStringAsFixed(0)} م³'),
                                    Text('القراءة الحالية: ${_selectedHouse!['current_read'].toStringAsFixed(0)} م³'),
                                    Text('الاستهلاك: ${_selectedHouse!['usage'].toStringAsFixed(0)} م³', style: const TextStyle(fontWeight: FontWeight.bold)),
                                    const Divider(),
                                    Text('المبلغ المطلوب: ${_selectedHouse!['fee_collected'].toStringAsFixed(0)} د.ع', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              )
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_selectedAgentForMap != null)
                    Positioned(
                      top: 20, right: 20,
                      child: Card(
                        elevation: 8,
                        child: Container(
                          width: 300, padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                Text('${_selectedAgentForMap!['role']}: ${_selectedAgentForMap!['id']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.blue)),
                                IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => setState(() => _selectedAgentForMap = null), padding: EdgeInsets.zero, constraints: const BoxConstraints())
                              ]),
                              const Divider(),
                              Text('الزيارات اليوم: ${_selectedAgentForMap!['visits']}'),
                              const SizedBox(height: 12),
                              ElevatedButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _selectedTabIndex = 3; 
                                  });
                                },
                                icon: const Icon(Icons.message, size: 16),
                                label: const Text('فتح المراسلة المباشرة'),
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 36)),
                              )
                            ],
                          ),
                        ),
                      ),
                    )
                ],
              ),
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Container(
            margin: const EdgeInsets.only(top: 12, bottom: 12, left: 12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)]),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(16.0),
                  decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: const BorderRadius.vertical(top: Radius.circular(12))),
                  child: const Text('قوة العمل الميدانية (تتبع حي)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1B3B6F))),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _agents.length,
                    itemBuilder: (context, index) {
                      final a = _agents[index];
                      return ListTile(
                        leading: CircleAvatar(backgroundColor: a['role'] == 'مشرف' ? Colors.orange.shade100 : Colors.blue.shade50, child: Icon(a['role'] == 'مشرف' ? Icons.security : Icons.person, color: a['role'] == 'مشرف' ? Colors.orange : Colors.blue)),
                        title: Text(a['name'], style: TextStyle(fontWeight: a['role'] == 'مشرف' ? FontWeight.bold : FontWeight.normal, fontSize: 13)),
                        subtitle: Text(a['role'] == 'مشرف' ? 'جاهز للتسوية' : 'الزيارات: ${a['visits']}', style: const TextStyle(fontSize: 11)),
                        trailing: const Icon(Icons.my_location, color: Colors.green, size: 16),
                        onTap: () {},
                      );
                    },
                  ),
                )
              ],
            ),
          ),
        )
      ],
    );
  }

  // --- TAB 2: MANAGERIAL & HARDWARE ANALYTICS ---
  Widget _buildAnalyticsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('لوحة التحليل الإداري وأداء الخوادم', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF1B3B6F))),
          const SizedBox(height: 24),
          
          const Text('مؤشرات التشغيل ومركز الاتصال (Call Center)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildAnalyticCard('نسبة نجاح المكالمات', '94.2%', 'معدل الاتصال الناجح', Colors.teal, Icons.phone_in_talk)),
              const SizedBox(width: 16),
              Expanded(child: _buildAnalyticCard('نسبة إكمال المواعيد', '88.5%', 'حجوزات مكتملة', Colors.green, Icons.task_alt)),
              const SizedBox(width: 16),
              Expanded(child: _buildAnalyticCard('الشكاوى النشطة', '45', 'بلاغ قيد المعالجة', Colors.purple, Icons.support_agent)),
              const SizedBox(width: 16),
              Expanded(child: _buildAnalyticCard('متوسط زمن معالجة الشكوى', '4.2', 'ساعة لكل شكوى', Colors.blueGrey, Icons.access_time)),
            ],
          ),
          const SizedBox(height: 24),

          const Text('استهلاك الخوادم والطاقة الكهربائية (Server & Power Infrastructure)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _buildAnalyticCard('استهلاك المعالج (CPU)', '42.8%', 'Load Average (8 Cores)', Colors.amber.shade800, Icons.memory)),
              const SizedBox(width: 16),
              Expanded(child: _buildAnalyticCard('استهلاك الذاكرة (RAM)', '28.4 GB', 'من أصل 64 GB مخصصة', Colors.deepOrange, Icons.storage)),
              const SizedBox(width: 16),
              Expanded(child: _buildAnalyticCard('استهلاك الطاقة (Power)', '480 W', 'استهلاك الخوادم الحالي', Colors.redAccent, Icons.bolt)),
              const SizedBox(width: 16),
              Expanded(child: _buildAnalyticCard('الطاقة المستهلكة (kWh)', '11.5 kWh', 'خلال الـ 24 ساعة الماضية', Colors.blueGrey, Icons.electric_meter)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAnalyticCard(String title, String mainValue, String subValue, Color color, IconData icon) {
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
            Text(mainValue, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 4),
            Text(subValue, style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ],
        ),
      ),
    );
  }

  // --- TAB 3: RECEIPTS LOG ---
  Widget _buildReceiptLogsTab() {
    return Container(
      padding: const EdgeInsets.all(24.0),
      child: Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: const BoxDecoration(color: Color(0xFF1B3B6F), borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
              child: const Text('سجل الإيصالات المركزي (Audit Log)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.vertical,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(Colors.grey.shade100),
                    columns: const [
                      DataColumn(label: Text('رقم الوصل', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('الوقت', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('رقم العقار', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('معرف الجابي', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('المبلغ الإجمالي', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('أجور الشركة', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('خزينة الدولة', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('حالة التوثيق (OTP)', style: TextStyle(fontWeight: FontWeight.bold))),
                    ],
                    rows: _receiptLogs.map((r) => DataRow(
                      cells: [
                        DataCell(Text(r['rcpt_id'], style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue))),
                        DataCell(Text(r['time'])),
                        DataCell(Text(r['property'])),
                        DataCell(Text(r['agent'])),
                        DataCell(Text('${r['total']} د.ع', style: const TextStyle(fontWeight: FontWeight.bold))),
                        DataCell(Text('${r['company_share']} د.ع', style: const TextStyle(color: Colors.teal))),
                        DataCell(Text('${r['gov_share']} د.ع', style: const TextStyle(color: Colors.blueGrey))),
                        DataCell(Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: r['status'] == 'مكتمل (OTP)' ? Colors.green.shade50 : Colors.red.shade50,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(r['status'], style: TextStyle(color: r['status'] == 'مكتمل (OTP)' ? Colors.green : Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                        )),
                      ],
                    )).toList(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- TAB 4: MESSAGING & PINGS ---
  Widget _buildMessagesTab() {
    return Container(
      padding: const EdgeInsets.all(24.0),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Card(
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16.0),
                    color: Colors.grey.shade100,
                    width: double.infinity,
                    child: const Text('دليل الموظفين (المشرفين والجباة)', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1B3B6F))),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _agents.length,
                      itemBuilder: (context, index) {
                        final a = _agents[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: a['role'] == 'مشرف' ? Colors.orange.shade100 : Colors.blue.shade50,
                            child: Icon(a['role'] == 'مشرف' ? Icons.security : Icons.person, color: a['role'] == 'مشرف' ? Colors.orange : Colors.blue),
                          ),
                          title: Text(a['name'], style: TextStyle(fontWeight: a['role'] == 'مشرف' ? FontWeight.bold : FontWeight.normal, fontSize: 13)),
                          subtitle: Text(a['id'], style: const TextStyle(fontSize: 11)),
                          onTap: () {
                            _pingController.text = "توجيه للإدارة الميدانية: ";
                          },
                        );
                      },
                    ),
                  )
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 4,
            child: Card(
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16.0),
                    color: const Color(0xFF1B3B6F),
                    width: double.infinity,
                    child: const Text('لوحة إرسال التوجيهات (Push Notifications)', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      color: Colors.grey.shade50,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.message, size: 80, color: Colors.grey),
                          const SizedBox(height: 16),
                          const Text('اختر موظفاً من القائمة الجانبية أو اكتب تعميماً للجميع', style: TextStyle(color: Colors.grey, fontSize: 16)),
                          const SizedBox(height: 32),
                          TextField(
                            controller: _pingController,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: 'اكتب رسالة التوجيه هنا...',
                              border: OutlineInputBorder(),
                              fillColor: Colors.white,
                              filled: true,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إرسال التعميم لجميع المشرفين والجباة.'), backgroundColor: Colors.green));
                                    _pingController.clear();
                                  },
                                  icon: const Icon(Icons.campaign),
                                  label: const Text('تعميم للجميع (Broadcast)'),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    if (_pingController.text.isEmpty) return;
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إرسال الرسالة للموظف المحدد بنجاح.'), backgroundColor: Colors.green));
                                    _pingController.clear();
                                  },
                                  icon: const Icon(Icons.send),
                                  label: const Text('إرسال للموظف المحدد'),
                                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1B3B6F), foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
                                ),
                              ),
                            ],
                          )
                        ],
                      ),
                    ),
                  )
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}
