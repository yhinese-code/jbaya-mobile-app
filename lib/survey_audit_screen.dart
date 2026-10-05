import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'core/session.dart';

// Legacy survey screen from the prototype (POST /survey/audit-property). Not linked from the menus yet.

class SurveyAuditScreen extends StatefulWidget {
  const SurveyAuditScreen({super.key});

  @override
  State<SurveyAuditScreen> createState() => _SurveyAuditScreenState();
}

class _SurveyAuditScreenState extends State<SurveyAuditScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _serialController = TextEditingController();
  final TextEditingController _mahallaController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _readingController = TextEditingController();
  
  String _propertyStatus = 'legacy_mechanical'; // default tier
  bool _isLoading = false;

  Future<void> _submitSurveyRecord() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      await ApiClient.instance.post('/survey/audit-property', {
        "serial_number": _serialController.text.isEmpty ? null : _serialController.text,
        "mahalla": _mahallaController.text,
        "house_address": _addressController.text,
        "property_status": _propertyStatus,
        "surveyor_id": Session.instance.employeeCode,
        "initial_reading": double.tryParse(_readingController.text) ?? 0.0,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تسجيل العقار بنجاح في الشبكة الخاصة'), backgroundColor: Colors.green),
      );
      _formKey.currentState!.reset();
      _serialController.clear();
      _mahallaController.clear();
      _addressController.clear();
      _readingController.clear();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل مزامنة البيانات: ${e.message}'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح وتدقيق الأصول الميدانية'),
        backgroundColor: const Color(0xFF004D40),
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              const Text(
                'تسجيل وحدة سكنية جديدة / فحص حالة العداد',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textDirection: TextDirection.rtl,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _mahallaController,
                decoration: const InputDecoration(labelText: 'رقم المحلة (Mahalla Code)', border: OutlineInputBorder()),
                validator: (value) => value!.isEmpty ? 'يرجى إدخال رقم المحلة' : null,
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: _addressController,
                decoration: const InputDecoration(labelText: 'عنوان الدار / رقم الزقاق والدار', border: OutlineInputBorder()),
                validator: (value) => value!.isEmpty ? 'يرجى إدخال العنوان' : null,
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: _serialController,
                decoration: const InputDecoration(labelText: 'رقم العداد (اختياري إذا كان مفقوداً)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: _readingController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'قراءة العداد الحالية (أو التقديرية)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                value: _propertyStatus,
                decoration: const InputDecoration(labelText: 'حالة البنية التحتية للعداد', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'active_smart', child: Text('عداد ذكي فعال (Active NB-IoT)')),
                  DropdownMenuItem(value: 'legacy_mechanical', child: Text('عداد ميكانيكي تقليدي (OCR Required)')),
                  DropdownMenuItem(value: 'unmetered_target', child: Text('بدون عداد - أولوية نصب (Unmetered Target)')),
                ],
                onChanged: (val) => setState(() => _propertyStatus = val!),
              ),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                onPressed: _isLoading ? null : _submitSurveyRecord,
                icon: const Icon(Icons.cloud_upload),
                label: _isLoading 
                    ? const CircularProgressIndicator(color: Colors.white) 
                    : const Text('حزام ومزامنة البيان في الشبكة الخاصة', style: TextStyle(fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF004D40),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}