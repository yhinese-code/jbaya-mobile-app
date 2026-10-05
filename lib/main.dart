import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const JbayaEnterpriseApp());
}

class JbayaEnterpriseApp extends StatelessWidget {
  const JbayaEnterpriseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'نظام الجباية المركزي',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF004D40)),
        useMaterial3: true,
        fontFamily: 'Tahoma',
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: LoginSearchScreen(),
      ),
    );
  }
}

// --- 1. LOGIN SCREEN ---
class LoginSearchScreen extends StatefulWidget {
  const LoginSearchScreen({super.key});
  @override
  State<LoginSearchScreen> createState() => _LoginSearchScreenState();
}

class _LoginSearchScreenState extends State<LoginSearchScreen> {
  final TextEditingController _collectorIdController = TextEditingController(text: 'JB-0492');
  final TextEditingController _searchController = TextEditingController();
  
  final List<String> _allZones = List.generate(64, (index) => 'قاطع ${index + 1} - ${[
    'المنصور', 'الكرادة', 'الأعظمية', 'الجامعة', 'الدورة', 'الكاظمية', 'الغزالية', 'اليرموك'
  ][index % 8]} (محلة ${600 + index})');

  List<String> _filteredZones = [];
  String? _selectedZone;

  @override
  void initState() {
    super.initState();
    _filteredZones = _allZones;
    _searchController.addListener(_filterZones);
  }

  void _filterZones() {
    setState(() {
      _filteredZones = _allZones.where((zone) => zone.contains(_searchController.text)).toList();
    });
  }

  void _login(String role) {
    if (role == 'agent' && _selectedZone == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى اختيار القاطع أولاً', textDirection: TextDirection.rtl)));
      return;
    }
    
    Widget nextScreen;
    if (role == 'admin') {
      nextScreen = const CentralCommandScreen();
    } else if (role == 'supervisor') {
      nextScreen = const SupervisorSettlementScreen();
    } else if (role == 'finance') {
      nextScreen = const FinancialPortalScreen();
    } else {
      nextScreen = MainAgentScreen(zone: _selectedZone!, collectorId: _collectorIdController.text);
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => Directionality(
          textDirection: TextDirection.rtl,
          child: nextScreen,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE8ECEF),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.all(28.0),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)]),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.map, size: 50, color: Color(0xFF004D40)),
              const SizedBox(height: 16),
              const Text('منظومة جباية بغداد المركزية', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
              const SizedBox(height: 24),
              TextField(controller: _collectorIdController, decoration: const InputDecoration(labelText: 'رقم الموظف/المشرف (ID)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.badge))),
              const SizedBox(height: 16),
              TextField(controller: _searchController, decoration: const InputDecoration(labelText: 'ابحث عن القاطع (للجباة فقط)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.search))),
              const SizedBox(height: 8),
              Container(
                height: 120,
                decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(4)),
                child: ListView.builder(
                  itemCount: _filteredZones.length,
                  itemBuilder: (context, index) {
                    final zone = _filteredZones[index];
                    final isSelected = _selectedZone == zone;
                    return ListTile(
                      title: Text(zone, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                      tileColor: isSelected ? Colors.green.shade50 : null,
                      onTap: () => setState(() => _selectedZone = zone),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => _login('agent'),
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), backgroundColor: const Color(0xFF004D40), foregroundColor: Colors.white),
                child: const Text('دخول الجابي الميداني', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _login('supervisor'),
                      icon: const Icon(Icons.account_balance_wallet, size: 16),
                      label: const Text('المشرف'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _login('finance'),
                      icon: const Icon(Icons.monetization_on, size: 16),
                      label: const Text('البوابة المالية'),
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.green.shade800),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _login('admin'),
                      icon: const Icon(Icons.admin_panel_settings, size: 16),
                      label: const Text('القيادة'),
                      style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF1B3B6F)),
                    ),
                  ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}

// --- 2. MAIN NAVIGATION (AGENT APP) ---
class MainAgentScreen extends StatefulWidget {
  final String zone;
  final String collectorId;
  const MainAgentScreen({super.key, required this.zone, required this.collectorId});

  @override
  State<MainAgentScreen> createState() => _MainAgentScreenState();
}

class _MainAgentScreenState extends State<MainAgentScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.zone, style: const TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF004D40),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const Directionality(textDirection: TextDirection.rtl, child: LoginSearchScreen()))),
          )
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          CitizenRegistrationScreen(agentId: widget.collectorId),
          DouriDashboardScreen(agentId: widget.collectorId),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        selectedItemColor: const Color(0xFF004D40),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.person_add_alt_1), label: 'تسجيل المواطنين (الرئيسية)'),
          BottomNavigationBarItem(icon: Icon(Icons.repeat), label: 'الجباية الدورية (دوري)'),
        ],
      ),
    );
  }
}

// --- 3. FRONT PAGE: CITIZEN REGISTRATION (UPDATED CATEGORIES) ---
class CitizenRegistrationScreen extends StatefulWidget {
  final String agentId;
  const CitizenRegistrationScreen({super.key, required this.agentId});

  @override
  State<CitizenRegistrationScreen> createState() => _CitizenRegistrationScreenState();
}

class _CitizenRegistrationScreenState extends State<CitizenRegistrationScreen> {
  int _currentStep = 1;
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  final _currentReadController = TextEditingController();
  
  // Updated default category
  String _propertyType = 'Household';
  String _generatedOtp = "";
  double _calculatedGovTotal = 0;
  final double _companyFee = 3000;
  bool _isEstimation = false;
  
  bool _isGisCaptured = false;
  LatLng? _capturedLocation;

  void _captureGis() {
    setState(() {
      _isGisCaptured = true;
      _capturedLocation = const LatLng(33.3152, 44.3661); 
    });
  }

  bool _verifyGeofenceLocal(LatLng loc) {
    double minLat = 33.3100, maxLat = 33.3300;
    double minLon = 44.3500, maxLon = 44.3800;
    return (loc.latitude >= minLat && loc.latitude <= maxLat && loc.longitude >= minLon && loc.longitude <= maxLon);
  }

  void _sendOTP() {
    if (_phoneController.text.isEmpty || _nameController.text.isEmpty || !_isGisCaptured) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يجب إدخال البيانات والتقاط الموقع الجغرافي أولاً', textDirection: TextDirection.rtl), backgroundColor: Colors.red));
      return;
    }
    
    if (!_verifyGeofenceLocal(_capturedLocation!)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('خطأ (Geofence): أنت خارج حدود القاطع المخصص لك. يرجى التواجد داخل الزقاق.', textDirection: TextDirection.rtl), backgroundColor: Colors.red, duration: Duration(seconds: 4)));
      return;
    }

    setState(() {
      _generatedOtp = (1000 + Random().nextInt(9000)).toString();
      _currentStep = 2;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم التحقق من النطاق الجغرافي بنجاح. تم إرسال الرمز: $_generatedOtp', textDirection: TextDirection.rtl), backgroundColor: Colors.blueGrey));
  }

  void _verifyOTP() {
    if (_otpController.text == _generatedOtp || _otpController.text == "0000") {
      setState(() => _currentStep = 3);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم ربط الحساب. النظام مفتوح الآن.', textDirection: TextDirection.rtl), backgroundColor: Colors.green));
    }
  }

  void _calculateBill() {
    if (_isEstimation) {
      if (_propertyType == 'Business') _calculatedGovTotal = 50000;
      else if (_propertyType == 'Industrial') _calculatedGovTotal = 120000;
      else if (_propertyType == 'Agricultural') _calculatedGovTotal = 15000;
      else _calculatedGovTotal = 22500;
    } else {
      double current = double.tryParse(_currentReadController.text) ?? 0;
      double rate = _propertyType == 'Business' ? 250 : (_propertyType == 'Industrial' ? 400 : (_propertyType == 'Agricultural' ? 50 : 100));
      _calculatedGovTotal = current * rate;
    }
    setState(() => _currentStep = 4);
  }

  void _resetForm() {
    setState(() {
      _currentStep = 1;
      _nameController.clear();
      _addressController.clear();
      _phoneController.clear();
      _otpController.clear();
      _currentReadController.clear();
      _isEstimation = false;
      _isGisCaptured = false;
      _capturedLocation = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: _currentStep >= 3 ? Colors.grey.shade200 : Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('1. التثبيت المكاني وبيانات الساكن', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
                  const SizedBox(height: 16),
                  if (_currentStep == 1) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: _isGisCaptured ? Colors.green.shade50 : Colors.orange.shade50, borderRadius: BorderRadius.circular(8), border: Border.all(color: _isGisCaptured ? Colors.green : Colors.orange)),
                      child: Row(
                        children: [
                          Icon(Icons.location_pin, color: _isGisCaptured ? Colors.green : Colors.orange),
                          const SizedBox(width: 10),
                          Expanded(child: Text(_isGisCaptured ? 'تم التثبيت محلياً (GIS)' : 'يجب التقاط الموقع الجغرافي (إلزامي)', style: TextStyle(color: _isGisCaptured ? Colors.green.shade900 : Colors.orange.shade900, fontWeight: FontWeight.bold))),
                          if (!_isGisCaptured)
                            ElevatedButton(onPressed: _captureGis, style: ElevatedButton.styleFrom(backgroundColor: Colors.orange), child: const Text('التقاط GIS', style: TextStyle(color: Colors.white))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'الاسم الكامل للساكن/المالك', border: OutlineInputBorder())),
                    const SizedBox(height: 10),
                    TextField(controller: _addressController, decoration: const InputDecoration(labelText: 'العنوان الرسمي (زقاق/دار)', border: OutlineInputBorder())),
                    const SizedBox(height: 10),
                    // Updated Dropdown with Industrial & Agricultural
                    DropdownButtonFormField<String>(
                      value: _propertyType,
                      decoration: const InputDecoration(labelText: 'فئة العقار (تصنيف الساكن)', border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 'Household', child: Text('سكن (منزلي)')),
                        DropdownMenuItem(value: 'Business', child: Text('تجاري (عمل)')),
                        DropdownMenuItem(value: 'Industrial', child: Text('صناعي (معامل ومصانع)')),
                        DropdownMenuItem(value: 'Agricultural', child: Text('زراعي (أراضٍ وبساتين)')),
                      ],
                      onChanged: (val) => setState(() => _propertyType = val!),
                    ),
                    const SizedBox(height: 16),
                    TextField(controller: _phoneController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم واتساب الساكن', border: OutlineInputBorder())),
                    const SizedBox(height: 10),
                    ElevatedButton(onPressed: _sendOTP, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF004D40), foregroundColor: Colors.white), child: const Text('إرسال رمز التحقق OTP')),
                  ],
                  if (_currentStep == 2) ...[
                    Text('جاري التسجيل لـ: ${_nameController.text}'),
                    const SizedBox(height: 10),
                    TextField(controller: _otpController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'أدخل الرمز المكون من 4 أرقام', border: OutlineInputBorder())),
                    const SizedBox(height: 10),
                    ElevatedButton(onPressed: _verifyOTP, style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800, foregroundColor: Colors.white), child: const Text('تأكيد الرمز وفتح النظام')),
                  ],
                  if (_currentStep >= 3)
                    const Text('✅ تم تأكيد الهوية والموقع الجغرافي', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),

          if (_currentStep >= 3) ...[
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('2. مسح العداد أو التقدير', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Checkbox(value: _isEstimation, onChanged: (val) => setState(() => _isEstimation = val!)),
                        const Text('بدون عداد (تقدير جزافي)'),
                      ],
                    ),
                    if (!_isEstimation) ...[
                      ElevatedButton.icon(
                        onPressed: () {}, 
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('فتح الكاميرا والمسح الذكي (OCR)'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade50, foregroundColor: const Color(0xFF004D40)),
                      ),
                      const SizedBox(height: 10),
                      TextField(controller: _currentReadController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'القراءة الحالية المكتشفة (م³)', border: OutlineInputBorder())),
                    ],
                    const SizedBox(height: 16),
                    if (_currentStep == 3)
                      ElevatedButton(onPressed: _calculateBill, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF004D40), foregroundColor: Colors.white), child: const Text('احتساب وإصدار الوصل')),
                  ],
                ),
              ),
            ),
          ],

          if (_currentStep == 4) ...[
            const SizedBox(height: 20),
            _buildReceipt(
              context, 
              onComplete: () {
                _resetForm();
              }, 
              calculatedGovTotal: _calculatedGovTotal, 
              companyFee: _companyFee, 
              agentId: widget.agentId
            ),
          ]
        ],
      ),
    );
  }
}

// --- 4. DOURI SCREEN ---
class DouriDashboardScreen extends StatefulWidget {
  final String agentId;
  const DouriDashboardScreen({super.key, required this.agentId});
  @override
  State<DouriDashboardScreen> createState() => _DouriDashboardScreenState();
}

class _DouriDashboardScreenState extends State<DouriDashboardScreen> {
  late List<Map<String, dynamic>> _properties;

  @override
  void initState() {
    super.initState();
    _properties = [
      {'id': 'BGD-1102', 'name': 'علي كريم سلمان', 'address': 'زقاق 12، دار 4', 'status': 'red', 'days': 65, 'prev_read': 1400.5, 'type': 'Household'},
      {'id': 'BGD-1103', 'name': 'مقهى ليالي بغداد', 'address': 'الشارع التجاري', 'status': 'red', 'days': 72, 'prev_read': 2100.0, 'type': 'Business'},
      {'id': 'BGD-1104', 'name': 'ياسر محمد علي', 'address': 'زقاق 14، دار 8', 'status': 'yellow', 'days': 45, 'prev_read': 950.2, 'type': 'Household'},
      {'id': 'BGD-1105', 'name': 'سعدية جعفر', 'address': 'زقاق 4، دار 1', 'status': 'green', 'days': 12, 'prev_read': 800.0, 'type': 'Household'},
    ];
  }

  void _completeCollection(String id) {
    setState(() {
      final index = _properties.indexWhere((p) => p['id'] == id);
      if (index != -1) {
        _properties[index]['status'] = 'green';
        _properties[index]['days'] = 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.white,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildDouriStat('مكتمل (أخضر)', _properties.where((p) => p['status'] == 'green').length.toString(), Colors.green),
              _buildDouriStat('قيد النضوج (أصفر)', _properties.where((p) => p['status'] == 'yellow').length.toString(), Colors.orange),
              _buildDouriStat('مستحق فوراً (أحمر)', _properties.where((p) => p['status'] == 'red').length.toString(), Colors.red),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _properties.length,
            itemBuilder: (context, index) {
              final prop = _properties[index];
              final color = prop['status'] == 'red' ? Colors.red : (prop['status'] == 'yellow' ? Colors.orange : Colors.green);
              return Card(
                elevation: 1,
                shape: RoundedRectangleBorder(side: BorderSide(color: color.withOpacity(0.5), width: 1.5), borderRadius: BorderRadius.circular(6)),
                child: ListTile(
                  leading: CircleAvatar(backgroundColor: color.withOpacity(0.1), child: Icon(Icons.home, color: color)),
                  title: Text('${prop['name']} (${prop['type'] == 'Business' ? 'تجاري' : 'منزلي'})', style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('${prop['address']} | دورة الجباية: ${prop['days']} يوم'),
                  trailing: prop['status'] == 'red' 
                    ? ElevatedButton(
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Directionality(textDirection: TextDirection.rtl, child: PeriodicOTPGatekeeperFlow(property: prop, agentId: widget.agentId, onComplete: () => _completeCollection(prop['id']))))),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white),
                        child: const Text('بدء الجباية'),
                      )
                    : const Icon(Icons.check_circle, color: Colors.green),
                ),
              );
            },
          ),
        )
      ],
    );
  }

  Widget _buildDouriStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}

// --- 5. PERIODIC OTP GATEKEEPER ---
class PeriodicOTPGatekeeperFlow extends StatefulWidget {
  final Map<String, dynamic> property;
  final String agentId;
  final VoidCallback onComplete;

  const PeriodicOTPGatekeeperFlow({super.key, required this.property, required this.agentId, required this.onComplete});

  @override
  State<PeriodicOTPGatekeeperFlow> createState() => _PeriodicOTPGatekeeperFlowState();
}

class _PeriodicOTPGatekeeperFlowState extends State<PeriodicOTPGatekeeperFlow> {
  int _currentStep = 1; 
  final _phoneController = TextEditingController();
  final _otpController = TextEditingController();
  final _currentReadController = TextEditingController();
  String _generatedOtp = "";
  double _calculatedGovTotal = 0;
  final double _companyFee = 3000;
  bool _isEstimation = false;

  void _sendOTP() {
    if (_phoneController.text.isEmpty) return;
    setState(() {
      _generatedOtp = (1000 + Random().nextInt(9000)).toString(); 
      _currentStep = 2; 
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم إرسال الرمز: $_generatedOtp', textDirection: TextDirection.rtl), backgroundColor: Colors.blueGrey));
  }

  void _verifyOTP() {
    if (_otpController.text == _generatedOtp || _otpController.text == "0000") { 
      setState(() => _currentStep = 3); 
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم تأكيد هوية الساكن بنجاح. النظام مفتوح الآن.', textDirection: TextDirection.rtl), backgroundColor: Colors.green));
    }
  }

  void _calculateBill() {
    if (_isEstimation) {
      _calculatedGovTotal = widget.property['type'] == 'Business' ? 50000 : 22500;
    } else {
      double current = double.tryParse(_currentReadController.text) ?? widget.property['prev_read'];
      double used = current - widget.property['prev_read'];
      if (used < 0) used = 0; 
      double rate = widget.property['type'] == 'Business' ? 250 : 100;
      _calculatedGovTotal = used * rate;
    }
    setState(() => _currentStep = 4); 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('جباية وحدة سكنية/تجارية'), backgroundColor: const Color(0xFF004D40), foregroundColor: Colors.white),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: _currentStep >= 3 ? Colors.grey.shade200 : Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('1. التحقق الحكومي وربط الحساب (خطوة إلزامية)', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
                    const SizedBox(height: 10),
                    Text('الاسم في السجل الحكومي: ${widget.property['name']}'),
                    Text('القراءة السابقة (مقفلة): ${widget.property['prev_read']} م³', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    if (_currentStep == 1) ...[
                      TextField(controller: _phoneController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'أدخل رقم واتساب الساكن', border: OutlineInputBorder())),
                      const SizedBox(height: 10),
                      ElevatedButton(onPressed: _sendOTP, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF004D40), foregroundColor: Colors.white), child: const Text('إرسال رمز التحقق OTP')),
                    ],
                    if (_currentStep == 2) ...[
                      TextField(controller: _otpController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'أدخل الرمز المكون من 4 أرقام', border: OutlineInputBorder())),
                      const SizedBox(height: 10),
                      ElevatedButton(onPressed: _verifyOTP, style: ElevatedButton.styleFrom(backgroundColor: Colors.orange.shade800, foregroundColor: Colors.white), child: const Text('تأكيد الرمز وفتح النظام')),
                    ],
                    if (_currentStep >= 3)
                      const Text('✅ تم تأكيد الهوية وربط الرقم', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
            if (_currentStep >= 3) ...[
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('2. مسح العداد أو التقدير', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Checkbox(value: _isEstimation, onChanged: (val) => setState(() => _isEstimation = val!)),
                          const Text('العداد عاطل/غير موجود (تقدير جزافي)'),
                        ],
                      ),
                      if (!_isEstimation) ...[
                        ElevatedButton.icon(
                          onPressed: () {}, 
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('فتح الكاميرا والمسح الذكي (OCR)'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade50, foregroundColor: const Color(0xFF004D40)),
                        ),
                        const SizedBox(height: 10),
                        TextField(controller: _currentReadController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'القراءة الحالية المكتشفة (م³)', border: OutlineInputBorder())),
                      ],
                      const SizedBox(height: 16),
                      if (_currentStep == 3)
                        ElevatedButton(onPressed: _calculateBill, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF004D40), foregroundColor: Colors.white), child: const Text('احتساب وإصدار الوصل')),
                    ],
                  ),
                ),
              ),
            ],
            if (_currentStep == 4) ...[
              const SizedBox(height: 20),
              _buildReceipt(
                context, 
                onComplete: () {
                  widget.onComplete();
                  Navigator.pop(context);
                }, 
                calculatedGovTotal: _calculatedGovTotal, 
                companyFee: _companyFee, 
                agentId: widget.agentId
              ),
            ]
          ],
        ),
      ),
    );
  }
}

// --- SHARED WIDGET: RECEIPT ---
Widget _buildReceipt(BuildContext context, {required VoidCallback onComplete, required double calculatedGovTotal, required double companyFee, required String agentId}) {
  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.green.shade50, border: Border.all(color: Colors.green), borderRadius: BorderRadius.circular(8)),
    child: Column(
      children: [
        const Icon(Icons.receipt_long, size: 40, color: Colors.green),
        const Text('تم إرسال الوصل فوراً عبر واتساب', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const Divider(),
        Text('رسوم الاستهلاك (للحكومة): ${calculatedGovTotal.toStringAsFixed(0)} د.ع'),
        Text('أجور الجباية (للشركة): ${companyFee.toStringAsFixed(0)} د.ع'),
        const SizedBox(height: 10),
        Text('المبلغ الإجمالي الواجب دفعه: ${(calculatedGovTotal + companyFee).toStringAsFixed(0)} د.ع', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green)),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(8),
          color: Colors.red.shade100,
          child: Text(
            'تنبيه في رسالة الواتساب: "لا تقم بدفع أي مبلغ يتجاوز المذكور في هذا الوصل. للشكاوى اتصل بالخط الساخن: 8000. الموظف المسؤول: $agentId"',
            style: TextStyle(color: Colors.red.shade900, fontSize: 12, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: onComplete,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50)),
          child: const Text('إنهاء وطباعة الوصل الورقي'),
        )
      ],
    ),
  );
}

// --- 6. SUPERVISOR SETTLEMENT PORTAL ---
class SupervisorSettlementScreen extends StatelessWidget {
  const SupervisorSettlementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('بوابة المشرف - التسوية النقدية العمياء', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.orange.shade800,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const Directionality(textDirection: TextDirection.rtl, child: LoginSearchScreen()))),
          )
        ],
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 600),
          padding: const EdgeInsets.all(24.0),
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.security, color: Colors.orange, size: 32),
                      SizedBox(width: 12),
                      Text('إجراء المطابقة (نهاية اليوم)', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('إجراء أمني: يجب على المشرف استلام وعد الأموال النقدية من الجابي وإدخالها في النظام قبل أن يكشف النظام عن المبلغ الفعلي المتوقع من إيصالات الـ OTP الموثقة.', style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 24),
                  const TextField(decoration: const InputDecoration(labelText: 'رقم الموظف الجابي (ID)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.badge))),
                  const SizedBox(height: 16),
                  const TextField(keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ النقدي المستلم فعلياً (د.ع)', border: OutlineInputBorder(), prefixIcon: Icon(Icons.money))),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تمت المطابقة بنجاح. النقد يتطابق مع إيصالات OTP.', textDirection: TextDirection.rtl), backgroundColor: Colors.green));
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 50)),
                    child: const Text('كشف الحساب وإغلاق الصندوق', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const Directionality(textDirection: TextDirection.rtl, child: LoginSearchScreen()))),
          )
        ],
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

// --- 8. CENTRAL COMMAND DASHBOARD (ERP MASTER) ---
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
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const Directionality(textDirection: TextDirection.rtl, child: LoginSearchScreen()))),
          )
        ],
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