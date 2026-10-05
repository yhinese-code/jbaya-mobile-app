// On-device OCR is only available on Android/iOS (Google ML Kit). On web it returns null.
export 'ocr_stub.dart' if (dart.library.io) 'ocr_mlkit.dart';
