import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import 'cc_widgets.dart';

/// Replays one employee's day: GPS trail, where he collected, and a time slider with play/pause.
class TrailTab extends StatefulWidget {
  final String? initialEmployee;
  const TrailTab({super.key, this.initialEmployee});

  @override
  State<TrailTab> createState() => _TrailTabState();
}

class _TrailTabState extends State<TrailTab> {
  final _map = MapController();
  bool _mapReady = false;
  List<Map<String, dynamic>> _staff = [];
  String? _employee;
  DateTime _day = DateTime.now();
  Map<String, dynamic>? _trail;
  List<LatLng> _points = [];
  int _cursor = 0;
  bool _loading = false;
  String? _error;
  Timer? _player;

  @override
  void initState() {
    super.initState();
    _employee = widget.initialEmployee;
    _loadStaff();
    if (_employee != null) _loadTrail();
  }

  @override
  void didUpdateWidget(covariant TrailTab old) {
    super.didUpdateWidget(old);
    if (widget.initialEmployee != null && widget.initialEmployee != old.initialEmployee) {
      _employee = widget.initialEmployee;
      _day = DateTime.now();
      _loadTrail();
    }
  }

  @override
  void dispose() {
    _player?.cancel();
    _map.dispose();
    super.dispose();
  }

  Future<void> _loadStaff() async {
    try {
      final res = await ApiClient.instance.get('/command/live');
      if (!mounted) return;
      setState(() => _staff = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } on ApiException catch (_) {}
  }

  String get _dayParam => '${_day.year}-${_day.month.toString().padLeft(2, '0')}-${_day.day.toString().padLeft(2, '0')}';

  Future<void> _loadTrail() async {
    if (_employee == null) return;
    _player?.cancel();
    _player = null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.get('/command/trail/$_employee?day=$_dayParam');
      if (!mounted) return;
      final t = Map<String, dynamic>.from(res as Map);
      final pts = (t['points'] as List)
          .map((p) => LatLng((asNum(p['lat']) ?? 0).toDouble(), (asNum(p['lng']) ?? 0).toDouble()))
          .toList();
      setState(() {
        _trail = t;
        _points = pts;
        _cursor = pts.isEmpty ? 0 : pts.length - 1;
      });
      _fit();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _fit() {
    if (!_mapReady) return;
    final all = [..._points, ...polygonPoints(_trail?['sector']?['polygon'])];
    if (all.isEmpty) return;
    if (all.length == 1) {
      _map.move(all.first, 16);
      return;
    }
    _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(all), padding: const EdgeInsets.all(40), maxZoom: 18));
  }

  void _togglePlay() {
    if (_player != null) {
      _player!.cancel();
      setState(() => _player = null);
      return;
    }
    if (_points.length < 2) return;
    if (_cursor >= _points.length - 1) _cursor = 0;
    _player = Timer.periodic(const Duration(milliseconds: 250), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_cursor >= _points.length - 1) {
        t.cancel();
        setState(() => _player = null);
        return;
      }
      setState(() => _cursor++);
      if (_mapReady) _map.move(_points[_cursor], _map.camera.zoom);
    });
    setState(() {});
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now().subtract(const Duration(days: 90)),
      lastDate: DateTime.now(),
    );
    if (d != null && mounted) {
      setState(() => _day = d);
      _loadTrail();
    }
  }

  @override
  Widget build(BuildContext context) {
    final rawPoints = (_trail?['points'] as List?) ?? [];
    final stops = (_trail?['stops'] as List?) ?? [];
    final sectorPoly = polygonPoints(_trail?['sector']?['polygon']);
    final cursorPoint = _points.isEmpty ? null : _points[_cursor.clamp(0, _points.length - 1)];
    final cursorTime = rawPoints.isEmpty ? null : rawPoints[_cursor.clamp(0, rawPoints.length - 1)]['t'] as String?;
    final collected = stops.fold<double>(0, (s, x) => s + ((asNum(x['total_amount']) ?? 0).toDouble()));

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 320,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('trail-emp-$_employee-${_staff.length}'),
                  initialValue: _staff.any((s) => s['employee_code'] == _employee) ? _employee : null,
                  isExpanded: true,
                  dropdownColor: CC.panelHigh,
                  decoration: const InputDecoration(labelText: 'الموظف', border: OutlineInputBorder(), isDense: true),
                  items: _staff
                      .map((s) => DropdownMenuItem(
                            value: s['employee_code'] as String,
                            child: Text('${s['employee_code']} - ${s['full_name']}', overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) {
                    setState(() => _employee = v);
                    _loadTrail();
                  },
                ),
              ),
              OutlinedButton.icon(onPressed: _pickDay, icon: const Icon(Icons.calendar_month), label: Text(_dayParam)),
              if (_trail != null) ...[
                Chip(label: Text('المسافة ${_trail!['distance_km']} كم')),
                Chip(label: Text('نقاط الموقع ${rawPoints.length}')),
                Chip(label: Text('وصولات ${stops.length} | ${formatIqd(collected)}')),
              ],
              if (_loading) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: CC.danger))),
          const SizedBox(height: 12),
          Expanded(
            child: CCPanel(
              title: _employee == null ? 'اختر موظفاً لعرض مساره' : 'مسار $_employee - $_dayParam',
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: const LatLng(33.3152, 44.3661),
                    initialZoom: 14,
                    maxZoom: 19,
                    onMapReady: () {
                      _mapReady = true;
                      _fit();
                    },
                  ),
                  children: [
                    darkTiles(),
                    if (sectorPoly.length >= 3)
                      PolygonLayer(polygons: [
                        Polygon(points: sectorPoly, color: CC.accent.withValues(alpha: 0.07), borderColor: CC.accent, borderStrokeWidth: 2),
                      ]),
                    if (_points.length >= 2)
                      PolylineLayer(polylines: [
                        Polyline(points: _points, strokeWidth: 3, color: CC.accent.withValues(alpha: 0.45)),
                        Polyline(points: _points.sublist(0, _cursor + 1), strokeWidth: 4, color: CC.accent),
                      ]),
                    CircleLayer(circles: [
                      for (int i = 0; i < rawPoints.length; i++)
                        if (rawPoints[i]['is_mocked'] == true || rawPoints[i]['inside_sector'] == false)
                          CircleMarker(point: _points[i], radius: 5, color: CC.danger),
                    ]),
                    MarkerLayer(markers: [
                      for (final s in stops)
                        Marker(
                          point: LatLng((asNum(s['lat']) ?? 0).toDouble(), (asNum(s['lng']) ?? 0).toDouble()),
                          width: 30,
                          height: 30,
                          child: Tooltip(
                            message: '${s['receipt_no']} | ${formatIqd(asNum(s['total_amount']))} | ${clock(s['t'] as String?)}'
                                '${s['verification_method'] == 'master_code' ? ' | رمز رئيسي' : ''}',
                            child: Icon(Icons.payments,
                                color: s['verification_method'] == 'master_code' ? CC.warn : CC.ok, size: 26),
                          ),
                        ),
                      if (_points.isNotEmpty)
                        Marker(point: _points.first, width: 24, height: 24, child: const Icon(Icons.flag, color: CC.ok, size: 22)),
                      if (cursorPoint != null)
                        Marker(
                          point: cursorPoint,
                          width: 26,
                          height: 26,
                          child: Container(
                            decoration: BoxDecoration(
                              color: CC.accent,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                          ),
                        ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
          if (_points.length >= 2)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  IconButton.filled(
                    onPressed: _togglePlay,
                    icon: Icon(_player != null ? Icons.pause : Icons.play_arrow),
                    tooltip: _player != null ? 'إيقاف' : 'تشغيل المسار',
                  ),
                  Expanded(
                    child: Slider(
                      value: _cursor.toDouble(),
                      min: 0,
                      max: (_points.length - 1).toDouble(),
                      onChanged: (v) {
                        setState(() => _cursor = v.round());
                        if (_mapReady) _map.move(_points[_cursor], _map.camera.zoom);
                      },
                    ),
                  ),
                  SizedBox(width: 70, child: Text(clock(cursorTime), textAlign: TextAlign.center)),
                ],
              ),
            ),
          if (_trail != null && _points.isEmpty)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('لا توجد بيانات موقع لهذا اليوم (التطبيق يرسل الموقع كل 30 ثانية أثناء فتحه)',
                  style: TextStyle(color: CC.muted)),
            ),
        ],
      ),
    );
  }
}
