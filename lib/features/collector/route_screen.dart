import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/location_service.dart';
import 'collection_screen.dart';

/// Periodic collection for the collector's sector (assigned by the server):
/// list or map, search, and "nearest first".
class RouteScreen extends StatefulWidget {
  final VoidCallback? onCollected;
  const RouteScreen({super.key, this.onCollected});

  @override
  State<RouteScreen> createState() => RouteScreenState();
}

class RouteScreenState extends State<RouteScreen> {
  List<Map<String, dynamic>> _properties = [];
  List<LatLng> _sectorPolygon = [];
  bool _loading = true;
  String? _error;
  bool _mapView = false;
  String _query = '';
  String? _colorFilter; // red / yellow / green / null = all
  LatLng? _me;
  bool _locating = false;
  static const _distance = Distance();

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiClient.instance.get('/collector/route');
      if (!mounted) return;
      final list = (res['properties'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final poly = (res['sector']?['polygon'] as List? ?? [])
          .map((p) => LatLng((asNum((p as List)[0]) ?? 0).toDouble(), (asNum(p[1]) ?? 0).toDouble()))
          .toList();
      setState(() {
        _properties = list;
        _sectorPolygon = poly;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _locate() async {
    setState(() => _locating = true);
    try {
      final fix = await LocationService.current();
      if (mounted) setState(() => _me = LatLng(fix.lat, fix.lng));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  double? _metersTo(Map<String, dynamic> p) {
    if (_me == null) return null;
    return _distance.as(LengthUnit.Meter, _me!, LatLng((asNum(p['lat']) ?? 0).toDouble(), (asNum(p['lng']) ?? 0).toDouble()));
  }

  List<Map<String, dynamic>> get _visible {
    final q = _query.trim();
    var list = _properties.where((p) {
      if (_colorFilter != null && p['status_color'] != _colorFilter) return false;
      if (q.isEmpty) return true;
      return '${p['citizen_name']} ${p['property_code']} ${p['address']}'.contains(q);
    }).toList();
    if (_me != null) {
      list.sort((a, b) => (_metersTo(a) ?? 0).compareTo(_metersTo(b) ?? 0));
    }
    return list;
  }

  int _count(String color) => _properties.where((p) => p['status_color'] == color).length;

  Color _color(String? c) => c == 'red' ? Colors.red : (c == 'yellow' ? Colors.orange : Colors.green);

  Future<void> _open(Map<String, dynamic> prop) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CollectionScreen(property: prop)),
    );
    widget.onCollected?.call();
    if (mounted && (changed == true || prop['open_bill_id'] != null)) reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _stat('مستحق فوراً', _count('red'), 'red'),
                  _stat('قيد النضوج', _count('yellow'), 'yellow'),
                  _stat('مكتمل', _count('green'), 'green'),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      onChanged: (v) => setState(() => _query = v),
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search),
                        hintText: 'بحث بالاسم أو رقم العقار أو العنوان',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'الأقرب أولاً',
                    onPressed: _locating ? null : _locate,
                    icon: _locating
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.near_me, color: _me != null ? Colors.teal : null),
                  ),
                  IconButton.filledTonal(
                    tooltip: _mapView ? 'عرض القائمة' : 'عرض الخريطة',
                    onPressed: () => setState(() => _mapView = !_mapView),
                    icon: Icon(_mapView ? Icons.list : Icons.map),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Colors.red)),
            TextButton(onPressed: reload, child: const Text('إعادة المحاولة')),
          ],
        ),
      );
    }
    if (_properties.isEmpty) return const Center(child: Text('لا توجد عقارات مسجلة في قاطعك بعد'));
    return _mapView ? _map() : _list();
  }

  Widget _list() {
    final items = _visible;
    if (items.isEmpty) return const Center(child: Text('لا توجد نتائج'));
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final p = items[i];
          final color = _color(p['status_color'] as String?);
          final openStatus = p['open_bill_status'];
          final dist = _metersTo(p);
          String subtitle = '${p['address']} | ${propertyClassLabels[p['property_class']] ?? ''}\n';
          subtitle += p['never_paid'] == true ? 'لم تتم الجباية بعد (زيارة أولى)' : 'آخر جباية قبل ${p['days_since_paid']} يوم';
          if (dist != null) subtitle += ' | ${dist < 1000 ? '${dist.round()} م' : '${(dist / 1000).toStringAsFixed(1)} كم'}';
          if (openStatus == 'pending_approval') subtitle += ' | بانتظار موافقة المشرف';
          if (openStatus == 'blocked_review') subtitle += ' | قيد مراجعة المشرف';
          if (openStatus == 'awaiting_otp') subtitle += ' | بانتظار رمز المواطن';
          return Card(
            elevation: 1,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: color.withValues(alpha: 0.5), width: 1.5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: ListTile(
              leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.1), child: Icon(Icons.home, color: color)),
              title: Text('${p['citizen_name']} (${p['property_code']})', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(subtitle),
              isThreeLine: true,
              trailing: p['status_color'] == 'green' && openStatus == null
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : ElevatedButton(
                      onPressed: () => _open(p),
                      style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
                      child: Text(openStatus != null ? 'متابعة' : 'بدء الجباية'),
                    ),
              onTap: () => _open(p),
            ),
          );
        },
      ),
    );
  }

  Widget _map() {
    final items = _visible;
    final points = items.map((p) => LatLng((asNum(p['lat']) ?? 0).toDouble(), (asNum(p['lng']) ?? 0).toDouble())).toList();
    final center = _me ?? (points.isNotEmpty ? points.first : const LatLng(33.3152, 44.3661));
    return FlutterMap(
      options: MapOptions(initialCenter: center, initialZoom: 16),
      children: [
        TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.jbaya.app'),
        if (_sectorPolygon.length >= 3)
          PolygonLayer(polygons: [
            Polygon(
              points: _sectorPolygon,
              color: Colors.teal.withValues(alpha: 0.08),
              borderColor: Colors.teal,
              borderStrokeWidth: 2,
            ),
          ]),
        MarkerLayer(markers: [
          for (int i = 0; i < items.length; i++)
            Marker(
              point: points[i],
              width: 36,
              height: 36,
              child: GestureDetector(
                onTap: () => _open(items[i]),
                child: Tooltip(
                  message: '${items[i]['citizen_name']} - ${items[i]['property_code']}',
                  child: Icon(Icons.location_on, size: 36, color: _color(items[i]['status_color'] as String?)),
                ),
              ),
            ),
          if (_me != null)
            Marker(
              point: _me!,
              width: 22,
              height: 22,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                ),
              ),
            ),
        ]),
      ],
    );
  }

  Widget _stat(String label, int value, String color) {
    final c = _color(color);
    final selected = _colorFilter == color;
    return InkWell(
      onTap: () => setState(() => _colorFilter = selected ? null : color),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? c.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text('$value', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: c)),
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
