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

  /// Called when the server ends the session (daily logout, tech panel, device revoked, account suspended).
  static void Function(String message)? onSessionEnded;

  void setToken(String? token) => _token = token;

  bool get hasToken => _token != null;

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

  Future<dynamic> patch(String path, [Map<String, dynamic>? body]) {
    return _send(() => http.patch(_uri(path), headers: _headers, body: jsonEncode(body ?? <String, dynamic>{})));
  }

  Future<dynamic> delete(String path) {
    return _send(() => http.delete(_uri(path), headers: _headers));
  }

  Future<dynamic> _send(Future<http.Response> Function() call) async {
    http.Response res;
    try {
      res = await call().timeout(const Duration(seconds: 40));
    } on TimeoutException {
      // -1, not 0: the request may have reached the server, so it must not be saved again as offline work
      throw ApiException(-1, 'انتهت مهلة الاتصال بالخادم. تحقق من القائمة قبل الإعادة حتى لا يتكرر العمل');
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
    if (res.statusCode == 401 && _token != null) {
      _token = null;
      onSessionEnded?.call(message);
    }
    throw ApiException(res.statusCode, message);
  }
}
