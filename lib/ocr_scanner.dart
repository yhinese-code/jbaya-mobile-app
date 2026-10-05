import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

class OcrScannerScreen extends StatefulWidget {
  const OcrScannerScreen({super.key});

  @override
  State<OcrScannerScreen> createState() => _OcrScannerScreenState();
}

class _OcrScannerScreenState extends State<OcrScannerScreen> {
  final ImagePicker _picker = ImagePicker();
  String _scannedText = 'لم يتم مسح أي عداد بعد';
  bool _isProcessing = false;

  Future<void> _scanMeter() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.camera);
    if (image == null) return;

    setState(() {
      _isProcessing = true;
      _scannedText = 'جاري تحليل الصورة...';
    });

    final inputImage = InputImage.fromFilePath(image.path);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    
    try {
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
      
      // Basic extraction logic: looking for numeric sequences or "MCH-" serials
      String extracted = recognizedText.text;
      
      setState(() {
        _scannedText = extracted.isNotEmpty 
            ? 'القراءة المستخرجة:\n$extracted' 
            : 'لم يتم العثور على أرقام واضحة.';
      });
    } catch (e) {
      setState(() {
        _scannedText = 'خطأ في المسح: $e';
      });
    } finally {
      textRecognizer.close();
      setState(() {
        _isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('المسح الضوئي للعداد (OCR)'),
        backgroundColor: const Color(0xFF004D40),
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.camera_alt, size: 80, color: Colors.blueGrey),
              const SizedBox(height: 20),
              Text(
                _scannedText,
                textAlign: TextAlign.center,
                textDirection: TextDirection.rtl,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: _isProcessing ? null : _scanMeter,
                icon: _isProcessing 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) 
                    : const Icon(Icons.document_scanner),
                label: const Text('التقاط صورة للعداد'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                  backgroundColor: const Color(0xFF004D40),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}