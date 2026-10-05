/// Picks the most likely meter reading from OCR text.
/// Works line by line (the counter is usually on its own line, the serial number on another),
/// joins digits split by spaces (counter wheels), and keeps the longest run of 3-9 digits,
/// optionally with one decimal part.
double? pickMeterReading(String text) {
  String? best;
  int bestLen = 0;
  for (final line in text.split('\n')) {
    final compact = line.replaceAll(' ', '');
    for (final m in RegExp(r'\d{3,}(?:[.,]\d{1,3})?').allMatches(compact)) {
      final candidate = m.group(0)!;
      final len = candidate.replaceAll(RegExp(r'[.,]'), '').length;
      if (len > 9) continue; // phone numbers / long serials, not a counter
      if (len > bestLen) {
        best = candidate;
        bestLen = len;
      }
    }
  }
  if (best == null) return null;
  return double.tryParse(best.replaceAll(',', '.'));
}
