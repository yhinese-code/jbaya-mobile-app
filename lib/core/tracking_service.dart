import 'dart:async';

import 'api_client.dart';
import 'location_service.dart';

/// Sends the employee's position to the server every 30 seconds while the app is open.
/// Fixes taken while offline are queued and sent together when the connection returns.
/// (Tracking with the app closed needs an Android foreground service; planned for the mobile release.)
class TrackingService {
  TrackingService._();
  static final TrackingService instance = TrackingService._();

  static const Duration interval = Duration(seconds: 30);
  static const int _maxQueue = 500;

  Timer? _timer;
  final List<Map<String, dynamic>> _queue = [];
  bool _busy = false;
  DateTime? lastSentAt;
  String? lastError;

  bool get running => _timer != null;

  void start() {
    if (_timer != null) return;
    _tick();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _queue.clear();
  }

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      try {
        final fix = await LocationService.current().timeout(const Duration(seconds: 20));
        _queue.add({
          'lat': fix.lat,
          'lng': fix.lng,
          'accuracy_m': fix.accuracy,
          'is_mocked': fix.isMocked,
          'recorded_at': DateTime.now().toUtc().toIso8601String(),
        });
        if (_queue.length > _maxQueue) _queue.removeRange(0, _queue.length - _maxQueue);
      } catch (e) {
        lastError = e.toString();
      }
      if (_queue.isEmpty) return;
      final batch = List<Map<String, dynamic>>.from(_queue.take(100));
      await ApiClient.instance.post('/tracking/ping', {'points': batch});
      _queue.removeRange(0, batch.length);
      lastSentAt = DateTime.now();
      lastError = null;
    } on ApiException catch (e) {
      lastError = e.message; // keep the queue; retry next tick
      if (e.statusCode == 401 || e.statusCode == 403) {
        stop();
      } else if (e.statusCode == 413 || e.statusCode == 422) {
        _queue.clear(); // a malformed batch would otherwise block the queue forever
      }
    } finally {
      _busy = false;
    }
  }
}
