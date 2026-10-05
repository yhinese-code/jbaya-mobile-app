import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// Error with a user-facing Arabic message (taken from the server's "detail" field when available).
class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

/// Single HTTP client for the whole app. Holds the login token.
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  String? _token;

  void setToken(String? token) => _token = token;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Uri _uri(String path) => Uri.parse('${AppConfig.apiBaseUrl}$path');

  Future<dynamic> get(String path) {
    return _send(() => http.get(_uri(path), headers: _headers));
  }

  Future<dynamic> post(String path, [Map<String, dynamic>? body]) {
    return _send(() => http.post(_uri(path), headers: _headers, body: jsonEncode(body ?? <String, dynamic>{})));
  }

  Future<dynamic> _send(Future<http.Response> Function() call) async {
    http.Response res;
    try {
      res = await call().timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw ApiException(0, 'انتهت مهلة الاتصال بالخادم، حاول مجدداً');
    } catch (_) {
      throw ApiException(0, 'تعذر الاتصال بالخادم. تحقق من الإنترنت أو من تشغيل الخادم');
    }

    final text = utf8.decode(res.bodyBytes);
    dynamic data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      data = null;
    }

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return data;
    }

    String message = 'خطأ من الخادم (${res.statusCode})';
    if (data is Map && data['detail'] != null) {
      final detail = data['detail'];
      if (detail is String) {
        message = detail;
      } else if (detail is List && detail.isNotEmpty) {
        message = 'بيانات غير مكتملة أو غير صالحة، يرجى مراجعة الحقول';
      }
    }
    throw ApiException(res.statusCode, message);
  }
}
