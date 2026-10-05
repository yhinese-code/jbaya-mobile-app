import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import 'ocr_parse.dart';

/// Reads the meter number with ML Kit. Never throws: any failure (unsupported platform, unreadable photo) -> null.
Future<double?> readMeterDigits(XFile file) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recognizer.processImage(InputImage.fromFilePath(file.path));
    return pickMeterReading(result.text);
  } catch (_) {
    return null;
  } finally {
    try {
      await recognizer.close();
    } catch (_) {}
  }
}
