import 'package:flutter/material.dart';

/// 25500 -> "25,500 د.ع"
String formatIqd(num? value) {
  if (value == null) return '-';
  return '${formatNumber(value)} د.ع';
}

/// 1234567.4 -> "1,234,567"
String formatNumber(num? value, {int decimals = 0}) {
  if (value == null) return '-';
  final negative = value < 0;
  final fixed = value.abs().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final whole = parts[0];
  final buffer = StringBuffer();
  for (int i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buffer.write(',');
    buffer.write(whole[i]);
  }
  final result = parts.length > 1 ? '${buffer.toString()}.${parts[1]}' : buffer.toString();
  return negative ? '-$result' : result;
}

num? asNum(dynamic v) {
  if (v == null) return null;
  if (v is num) return v;
  return num.tryParse(v.toString());
}

const Map<String, String> propertyClassLabels = {
  'Household': 'سكن (منزلي)',
  'Business': 'تجاري (عمل)',
  'Industrial': 'صناعي (معامل ومصانع)',
  'Agricultural': 'زراعي (أراضٍ وبساتين)',
};

const Map<String, String> meterStatusLabels = {
  'working': 'عداد عامل',
  'broken': 'عداد عاطل',
  'none': 'لا يوجد عداد',
};

/// 2026-10-06 (local date part of an ISO string or DateTime)
String formatDate(dynamic v) {
  final t = v is DateTime ? v : DateTime.tryParse('${v ?? ''}');
  if (t == null) return '-';
  final l = (v is String && v.length <= 10) ? t : t.toLocal();
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}

/// 08:15
String formatTime(dynamic v) {
  final t = DateTime.tryParse('${v ?? ''}')?.toLocal();
  if (t == null) return '-';
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String apiDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const Map<String, String> roleLabels = {
  'collector': 'جابي',
  'supervisor': 'مشرف',
  'finance': 'مالية',
  'command': 'قيادة',
  'hr': 'موارد بشرية',
  'admin': 'مدير النظام',
};

const Map<String, String> leaveStatusLabels = {
  'pending_supervisor': 'بانتظار المشرف',
  'pending_hr': 'بانتظار الموارد البشرية',
  'approved': 'معتمدة',
  'rejected': 'مرفوضة',
  'cancelled': 'ملغاة',
};

const Map<String, String> expenseCategoryLabels = {
  'fuel': 'وقود',
  'phone': 'رصيد هاتف',
  'transport': 'نقل',
  'repair': 'تصليح',
  'other': 'أخرى',
};

const Map<String, String> expenseStatusLabels = {
  'pending': 'بانتظار الموافقة',
  'approved': 'موافق عليها',
  'rejected': 'مرفوضة',
  'paid': 'صُرفت مع الراتب',
};

const Map<String, String> custodyTypeLabels = {
  'phone': 'هاتف',
  'meter_reader': 'جهاز قراءة',
  'printer': 'طابعة',
  'vehicle': 'مركبة',
  'uniform': 'زي',
  'cash_bag': 'حقيبة نقد',
  'other': 'أخرى',
};

const Map<String, String> disciplineLabels = {
  'verbal_warning': 'تنبيه شفهي',
  'written_warning': 'إنذار كتابي',
  'final_warning': 'إنذار نهائي',
  'penalty': 'عقوبة مالية',
  'suspension': 'إيقاف عن العمل',
};

Color statusColor(String? s) {
  switch (s) {
    case 'approved':
    case 'paid':
    case 'completed':
    case 'present':
    case 'returned':
      return const Color(0xFF2E7D32);
    case 'rejected':
    case 'absent':
    case 'lost':
      return const Color(0xFFC62828);
    case 'cancelled':
    case 'weekend':
      return const Color(0xFF757575);
    default:
      return const Color(0xFFEF6C00);
  }
}

/// Arabic count of houses with correct agreement: منزل واحد، منزلان، 3 منازل، 11 منزلاً
String housesAr(int n) {
  if (n == 1) return 'منزل واحد';
  if (n == 2) return 'منزلان';
  if (n >= 3 && n <= 10) return '$n منازل';
  return '$n منزلاً';
}
