import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/format.dart';

/// Shared look for the Central Command (dark "video wall").
class CC {
  static const bg = Color(0xFF0B1220);
  static const panel = Color(0xFF131C2E);
  static const panelHigh = Color(0xFF1B2740);
  static const border = Color(0xFF26324A);
  static const accent = Color(0xFF4F8CFF);
  static const text = Color(0xFFE6EDF7);
  static const muted = Color(0xFF8A97AD);
  static const ok = Color(0xFF2ECC71);
  static const warn = Color(0xFFF5A623);
  static const danger = Color(0xFFFF4D4F);
  static const critical = Color(0xFFFF1F4B);

  static ThemeData theme(BuildContext context) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Tahoma',
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark, surface: panel),
    );
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      cardTheme: const CardThemeData(color: panel, elevation: 0, margin: EdgeInsets.zero),
      dividerColor: border,
      navigationRailTheme: const NavigationRailThemeData(backgroundColor: panel),
    );
  }

  static Color severity(String s) => switch (s) {
        'critical' => critical,
        'high' => danger,
        'medium' => warn,
        'low' => muted,
        _ => accent,
      };

  static Color staffStatus(String s) => switch (s) {
        'sos' => critical,
        'online' => ok,
        'offline' => warn,
        _ => muted,
      };

  static String staffStatusLabel(String s) => switch (s) {
        'sos' => 'استغاثة',
        'online' => 'متصل',
        'offline' => 'انقطع الاتصال',
        _ => 'لم يبدأ',
      };

  static Color propertyColor(String? c) => c == 'red' ? danger : (c == 'yellow' ? warn : ok);
}

String timeAgo(String? iso) {
  final t = DateTime.tryParse(iso ?? '');
  if (t == null) return '-';
  final d = DateTime.now().difference(t.toLocal());
  if (d.inSeconds < 60) return 'قبل ${d.inSeconds < 0 ? 0 : d.inSeconds} ث';
  if (d.inMinutes < 60) return 'قبل ${d.inMinutes} د';
  if (d.inHours < 24) return 'قبل ${d.inHours} س';
  return 'قبل ${d.inDays} يوم';
}

String clock(String? iso) {
  final t = DateTime.tryParse(iso ?? '')?.toLocal();
  if (t == null) return '-';
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Dark panel with a title row.
class CCPanel extends StatelessWidget {
  final String title;
  final Widget child;
  final List<Widget> actions;
  final EdgeInsets padding;
  const CCPanel({super.key, required this.title, required this.child, this.actions = const [], this.padding = const EdgeInsets.all(12)});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CC.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CC.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Row(
              children: [
                Expanded(child: Text(title, style: const TextStyle(color: CC.text, fontWeight: FontWeight.bold, fontSize: 15))),
                ...actions,
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: Padding(padding: padding, child: child)),
        ],
      ),
    );
  }
}

class KpiTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final double? progress;
  final String? sub;
  const KpiTile({super.key, required this.label, required this.value, required this.icon, this.color = CC.accent, this.progress, this.sub});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 190,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CC.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text(label, style: const TextStyle(color: CC.muted, fontSize: 12), overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.bold)),
          ),
          if (sub != null) Text(sub!, style: const TextStyle(color: CC.muted, fontSize: 11)),
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: progress!.clamp(0.0, 1.0),
              color: color,
              backgroundColor: color.withValues(alpha: 0.15),
              minHeight: 5,
              borderRadius: BorderRadius.circular(4),
            ),
          ],
        ],
      ),
    );
  }
}

/// OpenStreetMap tiles darkened for the video wall.
/// For production, use your own tile server or a paid provider (OSM's public tiles are for light use).
Widget darkTiles() => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.jbaya.command',
      tileBuilder: darkModeTileBuilder,
    );

List<LatLng> polygonPoints(dynamic raw) {
  if (raw is! List) return [];
  return raw
      .whereType<List>()
      .where((p) => p.length >= 2)
      .map((p) => LatLng((asNum(p[0]) ?? 0).toDouble(), (asNum(p[1]) ?? 0).toDouble()))
      .toList();
}

String iqd(dynamic v) => formatIqd(asNum(v));
