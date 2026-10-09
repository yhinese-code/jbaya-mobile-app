import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';

/// Lightweight charts drawn with CustomPainter (no chart package needed).
/// Time always runs left -> right, even inside the RTL app.

/// Series colours for charts: distinguishable, calm, from the app palette (status colours only when the series means one).
class ChartColors {
  ChartColors._();
  static const primary = AppColors.brand;
  static const secondary = AppColors.info;
  static const tertiary = AppColors.warn;
  static const quiet = AppColors.faint;
}

class LineSeries {
  final String name;
  final List<double?> values;
  final Color color;
  final double width;
  final bool dashed;
  final bool fill;
  const LineSeries(this.name, this.values, this.color, {this.width = 2, this.dashed = false, this.fill = false});
}

class ChartBand {
  final List<double?> lower;
  final List<double?> upper;
  final Color color;
  const ChartBand(this.lower, this.upper, this.color);
}

String compactIqd(double v) {
  final a = v.abs();
  if (a >= 1e9) return '${(v / 1e9).toStringAsFixed(1)} مليار';
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(a >= 1e7 ? 0 : 1)} مليون';
  if (a >= 1e3) return '${(v / 1e3).toStringAsFixed(0)} ألف';
  return v.toStringAsFixed(0);
}

class SimpleLineChart extends StatefulWidget {
  final List<String> labels;
  final List<LineSeries> series;
  final ChartBand? band;
  final double height;
  final int? markerIndex; // vertical "today" line
  final String Function(double)? yFormat;
  const SimpleLineChart({
    super.key,
    required this.labels,
    required this.series,
    this.band,
    this.height = 240,
    this.markerIndex,
    this.yFormat,
  });

  @override
  State<SimpleLineChart> createState() => _SimpleLineChartState();
}

class _SimpleLineChartState extends State<SimpleLineChart> {
  int? _sel;

  void _pick(Offset p, Size size) {
    final n = widget.labels.length;
    if (n == 0) return;
    const left = _LinePainter.leftPad;
    final w = size.width - left - _LinePainter.rightPad;
    if (w <= 0) return;
    final i = n == 1 ? 0 : (((p.dx - left) / w) * (n - 1)).round().clamp(0, n - 1);
    setState(() => _sel = i);
  }

  @override
  Widget build(BuildContext context) {
    final fmt = widget.yFormat ?? compactIqd;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: widget.height,
            child: LayoutBuilder(builder: (context, c) {
              final size = Size(c.maxWidth, widget.height);
              return GestureDetector(
                onTapDown: (d) => _pick(d.localPosition, size),
                onHorizontalDragUpdate: (d) => _pick(d.localPosition, size),
                child: CustomPaint(
                  size: size,
                  painter: _LinePainter(widget.labels, widget.series, widget.band, widget.markerIndex, _sel, fmt,
                      Theme.of(context).brightness == Brightness.dark),
                ),
              );
            }),
          ),
          Directionality(
            textDirection: TextDirection.rtl,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 14,
                runSpacing: 4,
                children: [
                  for (final s in widget.series)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 14, height: 3, color: s.color),
                      const SizedBox(width: 4),
                      Text(s.name, style: const TextStyle(fontSize: 12)),
                    ]),
                  if (widget.band != null)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 14, height: 10, color: widget.band!.color),
                      const SizedBox(width: 4),
                      const Text('نطاق الثقة 95%', style: TextStyle(fontSize: 12)),
                    ]),
                  if (_sel != null && _sel! < widget.labels.length)
                    Text(
                      '${widget.labels[_sel!]}: ${widget.series.where((s) => _sel! < s.values.length && s.values[_sel!] != null).map((s) => '${s.name} ${formatNumber(s.values[_sel!])}').join(' | ')}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  static const leftPad = 56.0;
  static const rightPad = 10.0;
  static const topPad = 10.0;
  static const bottomPad = 24.0;

  final List<String> labels;
  final List<LineSeries> series;
  final ChartBand? band;
  final int? marker;
  final int? selected;
  final String Function(double) fmt;
  final bool dark;
  _LinePainter(this.labels, this.series, this.band, this.marker, this.selected, this.fmt, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    final n = labels.length;
    if (n == 0) return;
    final axis = dark ? Colors.white54 : AppColors.muted;
    final grid = dark ? Colors.white12 : AppColors.border;
    var maxV = 0.0;
    for (final s in series) {
      for (final v in s.values) {
        if (v != null && v > maxV) maxV = v;
      }
    }
    if (band != null) {
      for (final v in band!.upper) {
        if (v != null && v > maxV) maxV = v;
      }
    }
    if (maxV <= 0) maxV = 1;
    maxV = _niceMax(maxV);
    final w = size.width - leftPad - rightPad;
    final h = size.height - topPad - bottomPad;
    if (w <= 0 || h <= 0) return;
    double x(int i) => leftPad + (n == 1 ? w / 2 : w * i / (n - 1));
    double y(double v) => topPad + h - (v / maxV) * h;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var g = 0; g <= 4; g++) {
      final v = maxV * g / 4;
      final yy = y(v);
      canvas.drawLine(Offset(leftPad, yy), Offset(size.width - rightPad, yy), gridPaint);
      _text(canvas, fmt(v), Offset(leftPad - 6, yy), axis, alignRight: true);
    }
    final step = math.max(1, (n / 6).ceil());
    for (var i = 0; i < n; i += step) {
      _text(canvas, labels[i], Offset(x(i), size.height - bottomPad + 12), axis, center: true);
    }

    if (band != null) {
      final path = Path();
      var started = false;
      for (var i = 0; i < n && i < band!.upper.length; i++) {
        final v = band!.upper[i];
        if (v == null) continue;
        if (!started) {
          path.moveTo(x(i), y(v));
          started = true;
        } else {
          path.lineTo(x(i), y(v));
        }
      }
      for (var i = math.min(n, band!.lower.length) - 1; i >= 0; i--) {
        final v = band!.lower[i];
        if (v == null) continue;
        path.lineTo(x(i), y(v));
      }
      if (started) {
        path.close();
        canvas.drawPath(path, Paint()..color = band!.color);
      }
    }

    if (marker != null && marker! >= 0 && marker! < n) {
      final mx = x(marker!);
      _dashed(canvas, Offset(mx, topPad), Offset(mx, topPad + h), Paint()
        ..color = axis
        ..strokeWidth = 1);
    }

    for (final s in series) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      Offset? prev;
      final fillPath = Path();
      int? firstI;
      int? lastI;
      for (var i = 0; i < n && i < s.values.length; i++) {
        final v = s.values[i];
        if (v == null) {
          prev = null;
          continue;
        }
        final p = Offset(x(i), y(v));
        if (prev != null) {
          if (s.dashed) {
            _dashed(canvas, prev, p, paint);
          } else {
            canvas.drawLine(prev, p, paint);
          }
        }
        if (s.fill) {
          if (firstI == null) {
            fillPath.moveTo(p.dx, y(0));
            firstI = i;
          }
          fillPath.lineTo(p.dx, p.dy);
          lastI = i;
        }
        prev = p;
      }
      if (s.fill && firstI != null && lastI != null) {
        fillPath.lineTo(x(lastI), y(0));
        fillPath.close();
        canvas.drawPath(fillPath, Paint()..color = s.color.withValues(alpha: 0.12));
      }
    }

    if (selected != null && selected! < n) {
      final sx = x(selected!);
      canvas.drawLine(Offset(sx, topPad), Offset(sx, topPad + h), Paint()
        ..color = axis
        ..strokeWidth = 1);
      for (final s in series) {
        if (selected! < s.values.length && s.values[selected!] != null) {
          canvas.drawCircle(Offset(sx, y(s.values[selected!]!)), 4, Paint()..color = s.color);
        }
      }
    }
  }

  static double _niceMax(double v) {
    final exp = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    for (final m in [1.0, 2.0, 2.5, 5.0, 10.0]) {
      if (v <= m * exp) return m * exp;
    }
    return 10 * exp;
  }

  static void _dashed(Canvas canvas, Offset a, Offset b, Paint p) {
    final d = (b - a).distance;
    if (d == 0) return;
    final dir = (b - a) / d;
    var t = 0.0;
    while (t < d) {
      final e = math.min(t + 5, d);
      canvas.drawLine(a + dir * t, a + dir * e, p);
      t += 9;
    }
  }

  static void _text(Canvas canvas, String s, Offset at, Color color, {bool alignRight = false, bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: 10)),
      textDirection: TextDirection.rtl,
    )..layout();
    var dx = at.dx;
    if (alignRight) dx -= tp.width;
    if (center) dx -= tp.width / 2;
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _LinePainter oldDelegate) => true;
}

/// Vertical bars with an optional reference line (e.g. Benford's expected distribution).
class SimpleBarChart extends StatelessWidget {
  final List<String> labels;
  final List<double> values;
  final List<double>? reference;
  final Color color;
  final List<Color>? colors;
  final double height;
  final String Function(double)? yFormat;
  final String? valueName;
  final String? referenceName;
  const SimpleBarChart({
    super.key,
    required this.labels,
    required this.values,
    this.reference,
    this.color = AppColors.brand,
    this.colors,
    this.height = 220,
    this.yFormat,
    this.valueName,
    this.referenceName,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: height,
          child: CustomPaint(
            painter: _BarPainter(labels, values, reference, color, colors, yFormat ?? compactIqd,
                Theme.of(context).brightness == Brightness.dark),
          ),
        ),
        if (valueName != null || referenceName != null)
          Directionality(
            textDirection: TextDirection.rtl,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 14, children: [
                if (valueName != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 12, height: 12, color: color),
                    const SizedBox(width: 4),
                    Text(valueName!, style: const TextStyle(fontSize: 12)),
                  ]),
                if (referenceName != null)
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 14, height: 3, color: AppColors.bad),
                    const SizedBox(width: 4),
                    Text(referenceName!, style: const TextStyle(fontSize: 12)),
                  ]),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _BarPainter extends CustomPainter {
  final List<String> labels;
  final List<double> values;
  final List<double>? reference;
  final Color color;
  final List<Color>? colors;
  final String Function(double) fmt;
  final bool dark;
  _BarPainter(this.labels, this.values, this.reference, this.color, this.colors, this.fmt, this.dark);

  @override
  void paint(Canvas canvas, Size size) {
    final n = values.length;
    if (n == 0) return;
    const left = 48.0, right = 8.0, top = 8.0, bottom = 22.0;
    final axis = dark ? Colors.white54 : AppColors.muted;
    var maxV = values.fold<double>(0, math.max);
    if (reference != null) maxV = math.max(maxV, reference!.fold<double>(0, math.max));
    if (maxV <= 0) maxV = 1;
    maxV = _LinePainter._niceMax(maxV);
    final w = size.width - left - right;
    final h = size.height - top - bottom;
    if (w <= 0 || h <= 0) return;
    final slot = w / n;
    double y(double v) => top + h - (v / maxV) * h;
    final grid = Paint()
      ..color = dark ? Colors.white12 : AppColors.border
      ..strokeWidth = 1;
    for (var g = 0; g <= 4; g++) {
      final v = maxV * g / 4;
      canvas.drawLine(Offset(left, y(v)), Offset(size.width - right, y(v)), grid);
      _LinePainter._text(canvas, fmt(v), Offset(left - 6, y(v)), axis, alignRight: true);
    }
    for (var i = 0; i < n; i++) {
      final cx = left + slot * i + slot / 2;
      final bw = math.min(slot * 0.65, 48.0);
      final c = colors != null && i < colors!.length ? colors![i] : color;
      canvas.drawRRect(
        RRect.fromRectAndCorners(Rect.fromLTRB(cx - bw / 2, y(values[i]), cx + bw / 2, y(0)),
            topLeft: const Radius.circular(3), topRight: const Radius.circular(3)),
        Paint()..color = c,
      );
      if (i < labels.length) _LinePainter._text(canvas, labels[i], Offset(cx, size.height - bottom + 11), axis, center: true);
    }
    if (reference != null) {
      final p = Paint()
        ..color = AppColors.bad
        ..strokeWidth = 2;
      Offset? prev;
      for (var i = 0; i < n && i < reference!.length; i++) {
        final pt = Offset(left + slot * i + slot / 2, y(reference![i]));
        canvas.drawCircle(pt, 3, p);
        if (prev != null) canvas.drawLine(prev, pt, p);
        prev = pt;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter oldDelegate) => true;
}

/// Horizontal bar rows (good for Arabic names): label | bar | value.
class HBarList extends StatelessWidget {
  final List<({String label, double value, String? trailing})> rows;
  final Color color;
  const HBarList({super.key, required this.rows, this.color = AppColors.brand});

  @override
  Widget build(BuildContext context) {
    final maxV = rows.fold<double>(0, (m, r) => math.max(m, r.value));
    return LayoutBuilder(builder: (context, c) {
      // phones (~360px): narrower label/value columns so the bar keeps some room
      final narrow = c.maxWidth < 440;
      final labelW = narrow ? 104.0 : 150.0;
      final valueW = narrow ? 84.0 : 120.0;
      return Column(
        children: rows
            .map((r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                  child: Row(children: [
                    SizedBox(
                        width: labelW,
                        child: Text(r.label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: maxV > 0 ? r.value / maxV : 0,
                          minHeight: 12,
                          backgroundColor: color.withValues(alpha: 0.08),
                          valueColor: AlwaysStoppedAnimation(color),
                        ),
                      ),
                    ),
                    const SizedBox(width: Gap.sm),
                    SizedBox(
                        width: valueW,
                        child: Text(r.trailing ?? compactIqd(r.value),
                            textAlign: TextAlign.end,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold, fontFeatures: [FontFeature.tabularFigures()]))),
                  ]),
                ))
            .toList(),
      );
    });
  }
}

/// Small KPI card.
class KpiCard extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final IconData icon;
  final Color color;
  final double width;
  const KpiCard({super.key, required this.label, required this.value, required this.icon, required this.color, this.sub, this.width = 230});

  @override
  Widget build(BuildContext context) {
    // same look as AppCard: white, thin border; muted label on top, bold value below, small tinted icon.
    // On phones (~360px) two standard tiles sit side by side instead of one tile per row with a gap.
    return LayoutBuilder(builder: (context, c) {
      var w = width;
      if (c.hasBoundedWidth) {
        if (width <= 260 && c.maxWidth < 2 * width + Gap.sm && c.maxWidth < 560) {
          w = ((c.maxWidth - Gap.sm) / 2).floorToDouble();
        }
        if (w > c.maxWidth) w = c.maxWidth;
      }
      return _tile(w, compact: w < 200);
    });
  }

  Widget _tile(double width, {bool compact = false}) {
    final badge = Container(
      width: compact ? 28 : 36,
      height: compact ? 28 : 36,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(Gap.radiusSm)),
      child: Icon(icon, color: color, size: compact ? 16 : 20),
    );
    return SizedBox(
      width: width,
      child: AppCard(
        padding: const EdgeInsets.all(Gap.md),
        child: Flex(
          direction: compact ? Axis.vertical : Axis.horizontal,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
          badge,
          SizedBox(width: compact ? 0 : Gap.md, height: compact ? Gap.sm : 0),
          Flexible(
            fit: compact ? FlexFit.loose : FlexFit.tight,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted), maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(value,
                    maxLines: 1,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.ink, fontFeatures: [FontFeature.tabularFigures()])),
              ),
              if (sub != null) ...[
                const SizedBox(height: 2),
                Text(sub!, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

String pctText(dynamic v, {int digits = 0}) {
  final n = asNum(v);
  if (n == null) return '-';
  return '${(n * 100).toStringAsFixed(digits)}%';
}

String shortDay(String iso) => iso.length >= 10 ? '${iso.substring(8, 10)}/${iso.substring(5, 7)}' : iso;
