import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import 'cc_widgets.dart';
import 'property_dialog.dart';

/// The video wall: KPI strip, live map (sectors, properties, staff), field-force list and the live event feed.
/// Staff and KPIs refresh every 10 s, the feed every 5 s, property dots every 60 s.
class LiveOpsTab extends StatefulWidget {
  final void Function(String employeeCode) onOpenTrail;
  const LiveOpsTab({super.key, required this.onOpenTrail});

  @override
  State<LiveOpsTab> createState() => _LiveOpsTabState();
}

class _LiveOpsTabState extends State<LiveOpsTab> {
  final _map = MapController();
  bool _mapReady = false;

  Map<String, dynamic> _kpi = {};
  List<Map<String, dynamic>> _staff = [];
  List<Map<String, dynamic>> _sectors = [];
  List<Map<String, dynamic>> _properties = [];
  final List<Map<String, dynamic>> _feed = [];
  int _lastFeedId = 0;
  String _feedFilter = 'info';
  bool _showProperties = true;
  String? _selected;
  String? _error;
  DateTime? _updatedAt;
  final Set<int> _flashIds = {};
  bool _fittedOnce = false;
  final _propertySearch = TextEditingController();

  Timer? _fast;
  Timer? _feedTimer;
  Timer? _slow;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadFeed();
    _loadSlow();
    _fast = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
    _feedTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadFeed());
    _slow = Timer.periodic(const Duration(seconds: 60), (_) => _loadSlow());
  }

  @override
  void dispose() {
    _fast?.cancel();
    _feedTimer?.cancel();
    _slow?.cancel();
    _map.dispose();
    _propertySearch.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/command/overview'),
        ApiClient.instance.get('/command/live'),
      ]);
      if (!mounted) return;
      setState(() {
        _kpi = Map<String, dynamic>.from(res[0] as Map);
        _staff = (res[1] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _error = null;
        _updatedAt = DateTime.now();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _loadSlow() async {
    try {
      final res = await Future.wait([
        ApiClient.instance.get('/command/sectors'),
        ApiClient.instance.get('/command/properties'),
      ]);
      if (!mounted) return;
      setState(() {
        _sectors = (res[0] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _properties = (res[1] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      });
      if (!_fittedOnce) _fitAll();
    } on ApiException catch (_) {}
  }

  /// Zoom the map so every sector, property and field employee is visible.
  void _fitAll() {
    if (!_mapReady) return;
    final pts = <LatLng>[
      for (final s in _sectors) ...polygonPoints(s['polygon']),
      for (final p in _properties)
        if (p['lat'] != null) LatLng((asNum(p['lat']) ?? 0).toDouble(), (asNum(p['lng']) ?? 0).toDouble()),
      for (final s in _staff)
        if (s['lat'] != null) LatLng((asNum(s['lat']) ?? 0).toDouble(), (asNum(s['lng']) ?? 0).toDouble()),
    ];
    if (pts.isEmpty) return;
    _fittedOnce = true;
    if (pts.length == 1) {
      _map.move(pts.first, 16);
      return;
    }
    _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(48), maxZoom: 17));
  }

  void _searchProperty(String q) {
    final query = q.trim().toUpperCase();
    if (query.isEmpty) return;
    final hit = _properties.firstWhere(
      (p) => '${p['property_code']}'.toUpperCase().contains(query) || '${p['citizen_name'] ?? ''}'.contains(q.trim()),
      orElse: () => <String, dynamic>{},
    );
    if (hit.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لم يتم العثور على العقار')));
      return;
    }
    _focus(hit['lat'], hit['lng'], zoom: 18);
    showPropertyDialog(context, hit['property_code'] as String);
  }

  Future<void> _loadFeed() async {
    try {
      final res = await ApiClient.instance.get('/command/feed?after_id=$_lastFeedId&limit=100');
      if (!mounted) return;
      final items = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (items.isEmpty) return;
      final firstLoad = _lastFeedId == 0;
      setState(() {
        _feed.insertAll(0, items);
        if (_feed.length > 300) _feed.removeRange(300, _feed.length);
        _lastFeedId = items.map((i) => i['id'] as int).reduce((a, b) => a > b ? a : b);
        if (!firstLoad) _flashIds.addAll(items.map((i) => i['id'] as int));
      });
      if (!firstLoad) {
        final critical = items.where((i) => i['severity'] == 'critical').toList();
        if (critical.isNotEmpty && mounted) {
          final c = critical.first;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            backgroundColor: CC.critical,
            duration: const Duration(seconds: 12),
            content: Text('🚨 ${c['label']}: ${c['employee_code'] ?? ''} ${c['full_name'] ?? ''}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            action: (c['lat'] != null)
                ? SnackBarAction(label: 'عرض', textColor: Colors.white, onPressed: () => _focus(c['lat'], c['lng']))
                : null,
          ));
        }
        Future.delayed(const Duration(seconds: 8), () {
          if (mounted) setState(() => _flashIds.clear());
        });
      }
    } on ApiException catch (_) {}
  }

  void _focus(dynamic lat, dynamic lng, {double zoom = 17}) {
    final la = asNum(lat)?.toDouble();
    final ln = asNum(lng)?.toDouble();
    if (la == null || ln == null || !_mapReady) return;
    _map.move(LatLng(la, ln), zoom);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 1150;
      final kpis = _kpiStrip();
      if (wide) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              kpis,
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 300, child: _staffPanel()),
                    const SizedBox(width: 12),
                    Expanded(child: _mapPanel()),
                    const SizedBox(width: 12),
                    SizedBox(width: 360, child: _feedPanel()),
                  ],
                ),
              ),
            ],
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          kpis,
          const SizedBox(height: 12),
          SizedBox(height: 420, child: _mapPanel()),
          const SizedBox(height: 12),
          SizedBox(height: 420, child: _feedPanel()),
          const SizedBox(height: 12),
          SizedBox(height: 420, child: _staffPanel()),
        ],
      );
    });
  }

  Widget _kpiStrip() {
    final collected = asNum(_kpi['collected_today']) ?? 0;
    final target = asNum(_kpi['target_today']) ?? 0;
    final online = asNum(_kpi['online_staff']) ?? 0;
    final total = asNum(_kpi['total_collectors']) ?? 0;
    final sos = asNum(_kpi['open_sos']) ?? 0;
    final security = asNum(_kpi['security_events_today']) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            color: CC.danger.withValues(alpha: 0.15),
            child: Text('تعذر التحديث: $_error', style: const TextStyle(color: CC.danger)),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              KpiTile(
                label: 'المحصّل اليوم',
                value: formatIqd(collected),
                icon: Icons.payments,
                color: CC.ok,
                progress: target > 0 ? collected / target : null,
                sub: target > 0 ? 'من هدف ${formatIqd(target)}' : null,
              ),
              const SizedBox(width: 10),
              KpiTile(label: 'وصولات اليوم', value: '${_kpi['receipts_today'] ?? 0}', icon: Icons.receipt_long),
              const SizedBox(width: 10),
              KpiTile(
                label: 'الميدان المتصل',
                value: '$online / $total',
                icon: Icons.wifi_tethering,
                color: CC.accent,
                progress: total > 0 ? online / total : null,
              ),
              const SizedBox(width: 10),
              KpiTile(label: 'نقد لدى الجباة', value: formatIqd(asNum(_kpi['cash_in_transit'])), icon: Icons.account_balance_wallet, color: CC.warn),
              const SizedBox(width: 10),
              KpiTile(label: 'تسجيلات اليوم', value: '${_kpi['registrations_today'] ?? 0}', icon: Icons.person_add),
              const SizedBox(width: 10),
              KpiTile(label: 'استغاثات مفتوحة', value: '$sos', icon: Icons.sos, color: sos > 0 ? CC.critical : CC.muted),
              const SizedBox(width: 10),
              KpiTile(label: 'أحداث أمنية اليوم', value: '$security', icon: Icons.gpp_maybe, color: security > 0 ? CC.danger : CC.muted),
              const SizedBox(width: 10),
              KpiTile(label: 'الرمز الرئيسي اليوم', value: '${_kpi['master_code_uses_today'] ?? 0}', icon: Icons.key, color: CC.warn),
              const SizedBox(width: 10),
              KpiTile(label: 'فواتير قيد المراجعة', value: '${_kpi['bills_in_review'] ?? 0}', icon: Icons.rule),
              const SizedBox(width: 10),
              KpiTile(label: 'إيداعات بانتظار المالية', value: formatIqd(asNum(_kpi['deposits_pending_verification'])), icon: Icons.account_balance),
            ],
          ),
        ),
      ],
    );
  }

  Widget _mapPanel() {
    final polygons = <Polygon>[
      for (final s in _sectors)
        if (polygonPoints(s['polygon']).length >= 3)
          Polygon(
            points: polygonPoints(s['polygon']),
            color: CC.accent.withValues(alpha: 0.07),
            borderColor: CC.accent.withValues(alpha: 0.8),
            borderStrokeWidth: 2,
          ),
    ];
    final staffWithGps = _staff.where((s) => s['lat'] != null && s['lng'] != null).toList();
    return CCPanel(
      title: 'الخريطة الحية',
      padding: EdgeInsets.zero,
      actions: [
        if (_updatedAt != null)
          Text('آخر تحديث ${_updatedAt!.hour.toString().padLeft(2, '0')}:${_updatedAt!.minute.toString().padLeft(2, '0')}:${_updatedAt!.second.toString().padLeft(2, '0')}',
              style: const TextStyle(color: CC.muted, fontSize: 11)),
        const SizedBox(width: 8),
        SizedBox(
          width: 190,
          height: 32,
          child: TextField(
            controller: _propertySearch,
            onSubmitted: _searchProperty,
            style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              prefixIcon: Icon(Icons.search, size: 16),
              hintText: 'بحث عن عقار',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        IconButton(
          tooltip: 'إظهار الكل',
          onPressed: _fitAll,
          icon: const Icon(Icons.fit_screen, size: 20),
        ),
        FilterChip(
          label: const Text('العقارات', style: TextStyle(fontSize: 12)),
          selected: _showProperties,
          onSelected: (v) => setState(() => _showProperties = v),
          visualDensity: VisualDensity.compact,
        ),
      ],
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
        child: FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: const LatLng(33.3152, 44.3661),
            initialZoom: 13,
            maxZoom: 19,
            onMapReady: () {
              _mapReady = true;
              _fitAll();
            },
          ),
          children: [
            darkTiles(),
            PolygonLayer(polygons: polygons),
            if (_showProperties)
              MarkerLayer(markers: [
                for (final p in _properties)
                  Marker(
                    point: LatLng((asNum(p['lat']) ?? 0).toDouble(), (asNum(p['lng']) ?? 0).toDouble()),
                    width: 16,
                    height: 16,
                    child: GestureDetector(
                      onTap: () => showPropertyDialog(context, p['property_code'] as String),
                      child: Tooltip(
                        message: '${p['property_code']} - ${p['citizen_name'] ?? ''}',
                        child: Container(
                          decoration: BoxDecoration(
                            color: CC.propertyColor(p['status_color'] as String?),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 1.5),
                          ),
                        ),
                      ),
                    ),
                  ),
              ]),
            MarkerLayer(markers: [
              for (final s in staffWithGps)
                Marker(
                  point: LatLng((asNum(s['lat']) ?? 0).toDouble(), (asNum(s['lng']) ?? 0).toDouble()),
                  width: 120,
                  height: 56,
                  child: GestureDetector(
                    onTap: () => setState(() => _selected = s['employee_code'] as String),
                    child: _staffMarker(s),
                  ),
                ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _staffMarker(Map<String, dynamic> s) {
    final color = CC.staffStatus('${s['status']}');
    final selected = _selected == s['employee_code'];
    final isSupervisor = s['role'] == 'supervisor';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: CC.bg.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selected ? Colors.white : color),
          ),
          child: Text('${s['employee_code']}', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
        Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: selected ? 3 : 2),
            boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: s['status'] == 'sos' ? 16 : 6)],
          ),
          child: Icon(
            s['status'] == 'sos' ? Icons.sos : (isSupervisor ? Icons.shield : Icons.person),
            size: 15,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _staffPanel() {
    final order = {'sos': 0, 'offline': 1, 'online': 2, 'not_started': 3};
    final list = List<Map<String, dynamic>>.from(_staff)
      ..sort((a, b) => (order[a['status']] ?? 9).compareTo(order[b['status']] ?? 9));
    return CCPanel(
      title: 'القوة الميدانية (${_staff.length})',
      padding: EdgeInsets.zero,
      child: list.isEmpty
          ? const Center(child: Text('لا يوجد موظفون ميدانيون', style: TextStyle(color: CC.muted)))
          : ListView.separated(
              itemCount: list.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final s = list[i];
                final color = CC.staffStatus('${s['status']}');
                final selected = _selected == s['employee_code'];
                return Material(
                  color: selected ? CC.panelHigh : Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      setState(() => _selected = s['employee_code'] as String);
                      _focus(s['lat'], s['lng']);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(s['role'] == 'supervisor' ? Icons.shield : Icons.person, color: color, size: 18),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text('${s['employee_code']} - ${s['full_name']}',
                                    style: const TextStyle(color: CC.text, fontWeight: FontWeight.bold, fontSize: 13),
                                    overflow: TextOverflow.ellipsis),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
                                child: Text(CC.staffStatusLabel('${s['status']}'), style: TextStyle(color: color, fontSize: 11)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${s['sector_name'] ?? 'بدون قاطع'} | ${s['last_seen'] == null ? 'لا يوجد موقع' : timeAgo(s['last_seen'] as String?)}'
                            '${s['is_mocked'] == true ? ' | ⚠ موقع مزيف' : ''}${s['inside_sector'] == false ? ' | خارج القاطع' : ''}',
                            style: TextStyle(
                              color: (s['is_mocked'] == true || s['inside_sector'] == false) ? CC.danger : CC.muted,
                              fontSize: 11,
                            ),
                          ),
                          if (s['role'] == 'collector')
                            Text(
                              'اليوم ${formatIqd(asNum(s['collected_today']))} (${s['receipts_today']} وصل) | بحوزته ${formatIqd(asNum(s['cash_in_hand']))}'
                              '${(asNum(s['master_uses_today']) ?? 0) > 0 ? ' | رمز رئيسي ×${s['master_uses_today']}' : ''}',
                              style: const TextStyle(color: CC.muted, fontSize: 11),
                            ),
                          if (selected)
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: TextButton.icon(
                                onPressed: () => widget.onOpenTrail(s['employee_code'] as String),
                                icon: const Icon(Icons.timeline, size: 16),
                                label: const Text('عرض مسار اليوم'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _feedPanel() {
    const floors = {'info': 0, 'low': 1, 'medium': 2, 'high': 3, 'critical': 4};
    final floor = floors[_feedFilter] ?? 0;
    final items = _feed.where((f) => (floors[f['severity']] ?? 0) >= floor).toList();
    return CCPanel(
      title: 'الأحداث الحية',
      padding: EdgeInsets.zero,
      actions: [
        DropdownButton<String>(
          value: _feedFilter,
          underline: const SizedBox(),
          isDense: true,
          dropdownColor: CC.panelHigh,
          style: const TextStyle(color: CC.text, fontSize: 12),
          items: const [
            DropdownMenuItem(value: 'info', child: Text('الكل')),
            DropdownMenuItem(value: 'medium', child: Text('متوسط فأعلى')),
            DropdownMenuItem(value: 'high', child: Text('مهم فقط')),
          ],
          onChanged: (v) => setState(() => _feedFilter = v ?? 'info'),
        ),
      ],
      child: items.isEmpty
          ? const Center(child: Text('لا توجد أحداث', style: TextStyle(color: CC.muted)))
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, i) {
                final f = items[i];
                final color = CC.severity('${f['severity']}');
                final fresh = _flashIds.contains(f['id']);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  color: fresh ? color.withValues(alpha: 0.18) : Colors.transparent,
                  child: InkWell(
                    onTap: f['lat'] != null ? () => _focus(f['lat'], f['lng']) : null,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      decoration: BoxDecoration(
                        border: BorderDirectional(
                          start: BorderSide(color: color, width: 4),
                          bottom: const BorderSide(color: CC.border),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text('${f['label']}', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
                              ),
                              Text(clock(f['created_at'] as String?), style: const TextStyle(color: CC.muted, fontSize: 11)),
                            ],
                          ),
                          Text(
                            '${f['employee_code'] ?? ''} ${f['full_name'] ?? ''}${(f['text'] ?? '').toString().isNotEmpty ? ' | ${f['text']}' : ''}',
                            style: const TextStyle(color: CC.text, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
