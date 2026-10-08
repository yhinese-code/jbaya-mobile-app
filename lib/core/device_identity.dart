import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A random id created once per installation (per browser for the web build) and kept on the device.
/// The tech panel approves this id once; after that the device is bound to one account.
class DeviceIdentity {
  DeviceIdentity._();

  static const _key = 'jbaya_device_id';
  static String? _cached;

  static Future<String> id() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    var v = prefs.getString(_key);
    if (v == null || v.length < 16) {
      final r = Random.secure();
      v = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
      await prefs.setString(_key, v);
    }
    _cached = v;
    return v;
  }

  static String get platform => kIsWeb ? 'web' : defaultTargetPlatform.name;

  static String get label {
    if (kIsWeb) return 'متصفح ويب';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'هاتف أندرويد';
      case TargetPlatform.iOS:
        return 'آيفون';
      case TargetPlatform.windows:
        return 'حاسوب ويندوز';
      case TargetPlatform.macOS:
        return 'حاسوب ماك';
      default:
        return 'جهاز';
    }
  }
}
