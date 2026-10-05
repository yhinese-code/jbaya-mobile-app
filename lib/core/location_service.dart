import 'package:geolocator/geolocator.dart';

class GpsFix {
  final double lat;
  final double lng;
  final double accuracy;
  final bool isMocked;
  const GpsFix(this.lat, this.lng, this.accuracy, this.isMocked);
}

/// Real GPS position (replaces the hard-coded coordinate of the prototype).
/// The server re-checks the geofence, accuracy and mock-location flag; nothing here is trusted.
class LocationService {
  static Future<GpsFix> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('خدمة الموقع (GPS) مطفأة. يرجى تشغيلها');
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw Exception('يجب السماح للتطبيق بالوصول إلى الموقع');
    }
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 25)),
    );
    return GpsFix(p.latitude, p.longitude, p.accuracy, p.isMocked);
  }
}
