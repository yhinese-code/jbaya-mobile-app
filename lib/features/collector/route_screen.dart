import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/location_service.dart';
import '../../core/offline_queue.dart';
import '../../core/theme.dart';
import '../shared/ui.dart' show StatusChip;
import 'collection_screen.dart';
import 'verify_house_screen.dart';

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
  DateTime? _cachedAt; // set while showing the route saved on the phone (offline)
  static const _distance = Distance();
  final _queue = OfflineQueue.instance;

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
      _apply(res);
      _cachedAt = null;
      if (OfflineQueue.supported) {
        _queue.markOnline();
        unawaited(_queue.saveRoute(res));
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (OfflineQueue.supported && OfflineQueue.isConnectionError(e)) {
        _queue.markOffline();
        final cached = await _queue.loadRoute();
        if (!mounted) return;
        if (cached != null && cached['data'] != null) {
          _apply(cached['data']);
          setState(() => _cachedAt = DateTime.tryParse('${cached['saved_at']}'));
          return;
        }
      }
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _apply(dynamic res) {
    final list = (res['properties'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final poly = (res['sector']?['polygon'] as List? ?? [])
        .map((p) => LatLng((asNum((p as List)[0]) ?? 0).toDouble(), (asNum(p[1]) ?? 0).toDouble()))
        .toList();
    setState(() {
      _properties = list;
      _sectorPolygon = poly;
    });
  }

  Future<void> _locate() async {
    setState(() => _locating = true);
    try {
      final fix = await LocationService.current();
      if (mounted) setState(() => _me = LatLng(fix.lat, fix.lng));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', '')), backgroundColor: AppColors.bad),
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

  Color _color(String? c) => c == 'red' ? AppColors.bad : (c == 'yellow' ? AppColors.warn : AppColors.good);

  bool _pendingHouse(Map<String, dynamic> p) => p['needs_verification'] == true || p['status'] == 'pending_otp';

  Future<void> _open(Map<String, dynamic> prop) async {
    if (_pendingHouse(prop)) {
      // registered offline: confirm the citizen's number first; no billing until then
      await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => VerifyHouseScreen(property: prop)));
      widget.onCollected?.call();
      if (mounted) reload();
      return;
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CollectionScreen(property: prop)),
    );
    widget.onCollected?.call();
    if (mounted && (changed == true || prop['open_bill_id'] != null)) reload();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _queue,
      builder: (context, _) => Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _stat('مستحق فوراً', _count('red'), 'red')),
                    const SizedBox(width: Gap.sm),
                    Expanded(child: _stat('قيد النضوج', _count('yellow'), 'yellow')),
                    const SizedBox(width: Gap.sm),
                    Expanded(child: _stat('مكتمل', _count('green'), 'green')),
                  ],
                ),
                const SizedBox(height: Gap.sm),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        onChanged: (v) => setState(() => _query = v),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search),
                          hintText: 'بحث بالاسم أو رقم العقار أو العنوان',
                        ),
                      ),
                    ),
                    const SizedBox(width: Gap.xs),
                    IconButton.filledTonal(
                      tooltip: 'الأقرب أولاً',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: _locating ? null : _locate,
                      icon: _locating
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(Icons.near_me, color: _me != null ? AppColors.brand : null),
                    ),
                    IconButton.filledTonal(
                      tooltip: _mapView ? 'عرض القائمة' : 'عرض الخريطة',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: () => setState(() => _mapView = !_mapView),
                      icon: Icon(_mapView ? Icons.list : Icons.map_outlined),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_cachedAt != null || (OfflineQueue.supported && _queue.offline && !_loading))
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, 0),
              child: NoticeBanner(
                tone: Tone.warn,
                icon: Icons.cloud_off,
                title: 'دون اتصال',
                message: _cachedAt != null
                    ? 'القائمة محفوظة على الهاتف (آخر تحديث ${formatDate(_cachedAt)} ${formatTime(_cachedAt!.toUtc().toIso8601String())}). '
                        'يمكنك تسجيل القراءات وحفظها للمزامنة، ولا يمكن استلام المال حتى يعود الاتصال.'
                    : 'يمكنك تسجيل القراءات وحفظها للمزامنة، ولا يمكن استلام المال حتى يعود الاتصال.',
                action: TextButton.icon(onPressed: reload, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return EmptyState(
        icon: Icons.cloud_off,
        title: 'تعذر تحميل قائمة الجباية',
        message: _error,
        action: OutlinedButton.icon(onPressed: reload, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
      );
    }
    if (_properties.isEmpty) {
      return const EmptyState(icon: Icons.home_work_outlined, title: 'لا توجد عقارات مسجلة في قاطعك بعد');
    }
    return _mapView ? _map() : _list();
  }

  Widget _list() {
    final items = _visible;
    if (items.isEmpty) return const EmptyState(icon: Icons.search_off, title: 'لا توجد نتائج');
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xl),
        itemCount: items.length,
        itemBuilder: (context, i) => _tile(items[i]),
      ),
    );
  }

  Widget _tile(Map<String, dynamic> p) {
    final color = _color(p['status_color'] as String?);
    final openStatus = p['open_bill_status'];
    final dist = _metersTo(p);
    final queued = _queue.hasPendingReading(p['id']);
    final pendingHouse = _pendingHouse(p);
    final done = !pendingHouse && p['status_color'] == 'green' && openStatus == null;
    final notes = <String>[
      if (pendingHouse) 'سُجّل دون اتصال'
      else if (p['never_paid'] == true) 'لم تتم الجباية بعد (زيارة أولى)'
      else 'آخر جباية قبل ${p['days_since_paid']} يوم',
      if (dist != null) dist < 1000 ? '${dist.round()} م' : '${(dist / 1000).toStringAsFixed(1)} كم',
    ];
    String? state;
    Tone tone = Tone.info;
    if (pendingHouse) {
      state = null; // shown as a chip below
    } else if (queued) {
      state = 'قراءة محفوظة بانتظار المزامنة';
      tone = Tone.neutral;
    } else if (openStatus == 'pending_approval') {
      state = 'بانتظار موافقة المشرف';
      tone = Tone.warn;
    } else if (openStatus == 'blocked_review') {
      state = 'قيد مراجعة المشرف';
      tone = Tone.bad;
    } else if (openStatus == 'awaiting_otp') {
      state = 'بانتظار رمز المواطن';
    }
    return AppCard(
      accent: color,
      padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.md),
      onTap: () => _open(p),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${p['citizen_name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                Text('${p['property_code']}  ·  ${p['address']}', style: const TextStyle(color: AppColors.muted)),
                Text('${propertyClassLabels[p['property_class']] ?? ''}  ·  ${notes.join('  ·  ')}',
                    style: const TextStyle(fontSize: 12, color: AppColors.muted)),
                if (pendingHouse) ...[
                  const SizedBox(height: Gap.xs),
                  StatusChip('بانتظار تأكيد رقم المواطن', toneColor(Tone.warn)),
                ],
                if (state != null) ...[
                  const SizedBox(height: Gap.xs),
                  Text(state, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: toneColor(tone))),
                ],
              ],
            ),
          ),
          const SizedBox(width: Gap.sm),
          done
              ? const Icon(Icons.check_circle, color: AppColors.good, size: 28)
              : FilledButton(
                  onPressed: () => _open(p),
                  style: FilledButton.styleFrom(
                    backgroundColor: pendingHouse ? AppColors.warn : color,
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  ),
                  child: Text(pendingHouse ? 'تأكيد الرقم' : (openStatus != null ? 'متابعة' : 'بدء الجباية')),
                ),
        ],
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
              color: AppColors.brand.withValues(alpha: 0.08),
              borderColor: AppColors.brand,
              borderStrokeWidth: 2,
            ),
          ]),
        MarkerLayer(markers: [
          for (int i = 0; i < items.length; i++)
            Marker(
              point: points[i],
              width: 40,
              height: 40,
              child: GestureDetector(
                onTap: () => _open(items[i]),
                child: Tooltip(
                  message: '${items[i]['citizen_name']} - ${items[i]['property_code']}',
                  child: Icon(Icons.location_on, size: 40, color: _color(items[i]['status_color'] as String?)),
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
                  color: AppColors.info,
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
    return Material(
      color: selected ? c.withValues(alpha: 0.12) : AppColors.paper,
      borderRadius: BorderRadius.circular(Gap.radiusSm),
      child: InkWell(
        onTap: () => setState(() => _colorFilter = selected ? null : color),
        borderRadius: BorderRadius.circular(Gap.radiusSm),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Gap.radiusSm),
            border: Border.all(color: selected ? c : Colors.transparent),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('$value', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: c)),
              Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            ],
          ),
        ),
      ),
    );
  }
}
