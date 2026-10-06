import 'dart:convert';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import 'ocr/ocr_reader.dart';

class CapturedPhoto {
  final Uint8List bytes;
  final String base64;
  final double? ocrReading; // digits the phone's OCR found on the meter (null on web / when unreadable)
  const CapturedPhoto(this.bytes, this.base64, this.ocrReading);
}

/// Takes an evidence photo (meter, bank slip). Resized and compressed so uploads stay small on mobile data.
class PhotoService {
  static final ImagePicker _picker = ImagePicker();

  static Future<CapturedPhoto?> capture({bool runOcr = false, bool front = false}) async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.camera,
      preferredCameraDevice: front ? CameraDevice.front : CameraDevice.rear,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 70,
    );
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    double? ocr;
    if (runOcr) {
      ocr = await readMeterDigits(file);
    }
    return CapturedPhoto(bytes, base64Encode(bytes), ocr);
  }
}
