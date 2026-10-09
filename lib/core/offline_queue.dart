import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'api_client.dart';
import 'session.dart';

/// One piece of field work saved on the phone while there was no internet.
class OfflineItem {
  final int id;
  final String clientId;
  final String kind; // 'registration' | 'reading'
  final Map<String, dynamic> payload; // exact body for the server (incl. photo_base64)
  final String label; // what the collector sees in the list (name / property code)
  final String capturedAt; // ISO UTC, when it was recorded on the phone
  final String status; // pending | synced | failed
  final String? error; // server's Arabic message (failed, or a retryable problem)
  final Map<String, dynamic>? result; // server's answer for a synced item
  final String createdAt;

  const OfflineItem({
    required this.id,
    required this.clientId,
    required this.kind,
    required this.payload,
    required this.label,
    required this.capturedAt,
    required this.status,
    this.error,
    this.result,
    required this.createdAt,
  });

  bool get isRegistration => kind == 'registration';

  factory OfflineItem.fromRow(Map<String, Object?> r) {
    Map<String, dynamic>? decode(Object? v) {
      if (v == null) return null;
      try {
        final d = jsonDecode(v as String);
        return d is Map ? Map<String, dynamic>.from(d) : null;
      } catch (_) {
        return null;
      }
    }

    return OfflineItem(
      id: r['id'] as int,
      clientId: r['client_id'] as String,
      kind: r['kind'] as String,
      payload: decode(r['payload']) ?? const {},
      label: (r['label'] as String?) ?? '',
      capturedAt: r['captured_at'] as String,
      status: r['status'] as String,
      error: r['error'] as String?,
      result: decode(r['result']),
      createdAt: r['created_at'] as String,
    );
  }
}

class SyncReport {
  final int synced;
  final int failed;
  final int stillPending;
  final String? error; // why the sync stopped (no connection, server error)
  const SyncReport({this.synced = 0, this.failed = 0, this.stillPending = 0, this.error});
}

/// Offline field work (mobile only; on the web [supported] is false and nothing here is used).
///
/// Registrations and meter readings recorded without internet are kept in a small sqflite database
/// (jbaya_offline.db) and sent to POST /collector/offline/sync when the connection is back: automatically when
/// connectivity returns and when the collector app opens, or by the "sync now" button.
/// Each item has a random client_id so a repeated sync never creates the same house / bill twice on the server.
/// Items belong to the employee who recorded them; another account on the same phone never sends them.
///
/// Also keeps the last GET /collector/route answer so the visit list still opens offline.
class OfflineQueue extends ChangeNotifier {
  OfflineQueue._();
  static final OfflineQueue instance = OfflineQueue._();

  static const int batchSize = 20;
  static const int maxBatchChars = 1500000;
  static bool get supported => !kIsWeb;

  Database? _db;
  Future<void>? _opening;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  bool _online = true;
  bool _syncing = false;
  int _pending = 0;
  int _failed = 0;
  Set<int> _pendingReadingProperties = {};
  DateTime? lastSyncAt;
  String? lastSyncError;

  /// false when the phone has no network, or the last request could not reach the server.
  bool get online => _online;
  bool get offline => !_online;
  bool get syncing => _syncing;
  int get pendingCount => _pending;
  int get failedCount => _failed;

  /// Properties that already have a reading saved on the phone (shown on the route list).
  bool hasPendingReading(dynamic propertyId) => propertyId is int && _pendingReadingProperties.contains(propertyId);

  String get _owner => Session.instance.employeeCode;

  // ------------------------------------------------------------------ setup

  /// Opens the database, starts listening to connectivity and syncs anything left from before. Safe to call often.
  Future<void> init() async {
    if (!supported) return;
    try {
      await _open();
    } catch (e) {
      lastSyncError = 'تعذر فتح قاعدة البيانات على الهاتف: $e';
      return;
    }
    if (_connSub == null) {
      final c = Connectivity();
      _connSub = c.onConnectivityChanged.listen(_onConnectivity);
      try {
        _setOnline(_hasNetwork(await c.checkConnectivity()));
      } catch (_) {
        // plugin unavailable: rely on failed requests only
      }
    }
    await refresh();
    if (_online && _pending > 0) unawaited(sync());
  }

  Future<void> _open() {
    if (_db != null) return Future.value();
    return _opening ??= () async {
      try {
        await _openDb();
      } catch (_) {
        _opening = null; // let a later call try again
        rethrow;
      }
    }();
  }

  Future<void> _openDb() async {
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'jbaya_offline.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
            CREATE TABLE items (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              client_id TEXT NOT NULL UNIQUE,
              employee_code TEXT NOT NULL,
              kind TEXT NOT NULL,
              payload TEXT NOT NULL,
              label TEXT,
              captured_at TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'pending',
              error TEXT,
              result TEXT,
              created_at TEXT NOT NULL
            )''');
        await db.execute('CREATE INDEX items_owner_status ON items (employee_code, status)');
      },
    );
  }

  static bool _hasNetwork(List<ConnectivityResult> r) => r.any((e) => e != ConnectivityResult.none);

  void _onConnectivity(List<ConnectivityResult> r) {
    final now = _hasNetwork(r);
    final wasOffline = !_online;
    _setOnline(now);
    if (now && wasOffline && _pending > 0) unawaited(sync());
  }

  void _setOnline(bool v) {
    if (_online == v) return;
    _online = v;
    notifyListeners();
  }

  /// A request failed with no connection (ApiException statusCode 0).
  void markOffline() {
    if (supported) _setOnline(false);
  }

  /// A request reached the server.
  void markOnline() {
    if (supported) _setOnline(true);
  }

  /// No connection at all (0). A timeout (-1) is NOT one: the server may have saved the work already.
  static bool isConnectionError(Object e) => e is ApiException && e.statusCode == 0;

  // ------------------------------------------------------------------ queue

  static String newClientId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Saves a registration or a reading. [payload] is the exact body the live endpoint takes.
  Future<String> add({
    required String kind,
    required Map<String, dynamic> payload,
    required String label,
    DateTime? capturedAt,
  }) async {
    await _open();
    final id = newClientId();
    final now = DateTime.now().toUtc().toIso8601String();
    await _db!.insert('items', {
      'client_id': id,
      'employee_code': _owner,
      'kind': kind,
      'payload': jsonEncode(payload),
      'label': label,
      'captured_at': (capturedAt ?? DateTime.now()).toUtc().toIso8601String(),
      'status': 'pending',
      'created_at': now,
    });
    await refresh();
    return id;
  }

  /// This employee's items, newest first (synced items from the last 3 days only).
  Future<List<OfflineItem>> list() async {
    if (!supported) return const [];
    await _open();
    final since = DateTime.now().toUtc().subtract(const Duration(days: 3)).toIso8601String();
    final rows = await _db!.query(
      'items',
      where: "employee_code = ? AND (status != 'synced' OR created_at >= ?)",
      whereArgs: [_owner, since],
      orderBy: 'id DESC',
    );
    return rows.map(OfflineItem.fromRow).toList();
  }

  /// Removes an item the server refused (the collector decided to drop it). Only failed items can be removed.
  Future<void> remove(int id) async {
    await _open();
    await _db!.delete('items', where: "id = ? AND status = 'failed'", whereArgs: [id]);
    await refresh();
  }

  /// Recounts pending / failed items for the badge.
  Future<void> refresh() async {
    if (!supported) return;
    try {
      await _open();
    } catch (_) {
      return;
    }
    final rows = await _db!.query(
      'items',
      columns: ['kind', 'status', 'payload'],
      where: "employee_code = ? AND status != 'synced'",
      whereArgs: [_owner],
    );
    int pending = 0, failed = 0;
    final props = <int>{};
    for (final r in rows) {
      if (r['status'] == 'failed') {
        failed++;
      } else {
        pending++;
        if (r['kind'] == 'reading') {
          try {
            final pid = (jsonDecode(r['payload'] as String) as Map)['property_id'];
            if (pid is int) props.add(pid);
          } catch (_) {}
        }
      }
    }
    _pending = pending;
    _failed = failed;
    _pendingReadingProperties = props;
    notifyListeners();
  }

  // ------------------------------------------------------------------ sync

  /// Sends this employee's pending items in batches of [batchSize].
  Future<SyncReport> sync() async {
    if (!supported || _syncing) return SyncReport(stillPending: _pending);
    if (!ApiClient.instance.hasToken || _owner.isEmpty) return SyncReport(stillPending: _pending);
    await _open();
    _syncing = true;
    lastSyncError = null;
    notifyListeners();
    int synced = 0, failed = 0;
    String? stopError;
    try {
      final rows = await _db!.query(
        'items',
        where: "employee_code = ? AND status = 'pending'",
        whereArgs: [_owner],
        orderBy: 'captured_at ASC, id ASC',
      );
      final rawSizes = {for (final r in rows) r['id'] as int: (r['payload'] as String).length};
      final items = rows.map(OfflineItem.fromRow).toList();
      // up to [batchSize] items, and about [maxBatchChars] of JSON (meter photos) per request on slow mobile data
      final batches = <List<OfflineItem>>[];
      var current = <OfflineItem>[];
      var size = 0;
      for (final it in items) {
        final n = rawSizes[it.id] ?? 0;
        if (current.isNotEmpty && (current.length >= batchSize || size + n > maxBatchChars)) {
          batches.add(current);
          current = [];
          size = 0;
        }
        current.add(it);
        size += n;
      }
      if (current.isNotEmpty) batches.add(current);
      for (final batch in batches) {
        try {
          final r = await _sendBatch(batch);
          synced += r.$1;
          failed += r.$2;
        } on ApiException catch (e) {
          stopError = e.message;
          if (e.statusCode == 0) markOffline();   // a timeout (-1) just stops; the sync is safe to repeat
          break;
        }
      }
      if (stopError == null) lastSyncAt = DateTime.now();
      // the phone keeps synced items for 3 days (shown in the list), then forgets them
      final cutoff = DateTime.now().toUtc().subtract(const Duration(days: 3)).toIso8601String();
      await _db!.delete('items', where: "status = 'synced' AND created_at < ?", whereArgs: [cutoff]);
    } catch (e) {
      stopError = 'تعذرت المزامنة: $e';
    } finally {
      _syncing = false;
      lastSyncError = stopError;
      await refresh();
    }
    return SyncReport(synced: synced, failed: failed, stillPending: _pending, error: stopError);
  }

  /// Returns (synced, failed). A batch the server rejects as a whole (422) is retried one item at a time,
  /// so a single bad item can never block the others.
  Future<(int, int)> _sendBatch(List<OfflineItem> batch) async {
    Map<String, dynamic> body(OfflineItem it) => {
      ...it.payload,
      'client_id': it.clientId,
      'captured_at': it.capturedAt,
    };
    dynamic res;
    try {
      res = await ApiClient.instance.post('/collector/offline/sync', {
        'registrations': [for (final it in batch.where((b) => b.isRegistration)) body(it)],
        'readings': [for (final it in batch.where((b) => !b.isRegistration)) body(it)],
      });
    } on ApiException catch (e) {
      if (e.statusCode != 422) rethrow;
      if (batch.length == 1) {
        await _update(batch.first.id, status: 'failed', error: e.message);
        return (0, 1);
      }
      int s = 0, f = 0;
      for (final it in batch) {
        final r = await _sendBatch([it]);
        s += r.$1;
        f += r.$2;
      }
      return (s, f);
    }
    markOnline();
    final results = <String, Map<String, dynamic>>{};
    if (res is Map) {
      for (final key in ['registrations', 'readings']) {
        for (final r in (res[key] as List? ?? const [])) {
          if (r is Map && r['client_id'] != null) results['${r['client_id']}'] = Map<String, dynamic>.from(r);
        }
      }
    }
    int s = 0, f = 0;
    for (final it in batch) {
      final r = results[it.clientId];
      if (r == null) continue; // no answer for it: stays pending
      if (r['ok'] == true) {
        await _update(it.id, status: 'synced', result: r);
        s++;
      } else if (r['retry'] == true) {
        await _update(it.id, status: 'pending', error: '${r['error'] ?? 'تعذرت المزامنة، ستُعاد المحاولة'}');
      } else {
        await _update(it.id, status: 'failed', error: '${r['error'] ?? 'رفض الخادم هذا العمل'}', result: r);
        f++;
      }
    }
    return (s, f);
  }

  Future<void> _update(int id, {required String status, String? error, Map<String, dynamic>? result}) {
    return _db!.update(
      'items',
      {'status': status, 'error': error, if (result != null) 'result': jsonEncode(result)},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ------------------------------------------------------------------ cached data

  String get _routeKey => 'offline.route.$_owner';

  /// Keeps the last GET /collector/route answer for offline use.
  Future<void> saveRoute(dynamic data) async {
    if (!supported || data == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_routeKey, jsonEncode({'saved_at': DateTime.now().toIso8601String(), 'data': data}));
    } catch (_) {}
  }

  /// The cached route: {saved_at, data} or null.
  Future<Map<String, dynamic>?> loadRoute() async {
    if (!supported) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_routeKey);
      if (s == null) return null;
      return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return null;
    }
  }

  static const _numberKey = 'offline.business_number';

  /// The company's WhatsApp number, remembered from the last code screen (shown when saving offline).
  Future<void> rememberBusinessNumber(String? n) async {
    if (!supported || n == null || n.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_numberKey, n);
    } catch (_) {}
  }

  Future<String?> businessNumber() async {
    if (!supported) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_numberKey);
    } catch (_) {
      return null;
    }
  }
}

/// 9647700001111 -> "0770 000 1111" (local format, easier to read out and dial).
String formatWhatsappNumber(String? raw) {
  if (raw == null) return '';
  var d = raw.replaceAll(RegExp(r'\D'), '');
  if (d.startsWith('00964')) d = d.substring(5);
  if (d.startsWith('964')) d = d.substring(3);
  if (!d.startsWith('0')) d = '0$d';
  if (d.length == 11) return '${d.substring(0, 4)} ${d.substring(4, 7)} ${d.substring(7)}';
  return d;
}
