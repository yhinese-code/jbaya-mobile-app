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
