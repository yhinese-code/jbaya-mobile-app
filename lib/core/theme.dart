import 'package:flutter/material.dart';

/// One look for every portal (Phase 6 design pass).
///
/// Direction: a calm public-utility tool. Warm paper background, white cards with a thin border (no heavy shadows),
/// one deep-teal brand colour, and each portal recognisable by the colour of its top bar only. Status colours are
/// reserved for meaning (good / warning / problem / info) and never used as decoration.
/// Type: IBM Plex Sans Arabic (bundled in assets/fonts, works offline).
class AppColors {
  AppColors._();

  static const brand = Color(0xFF0B5A52);      // deep teal, the jibaya brand
  static const brandDark = Color(0xFF07403A);
  static const paper = Color(0xFFF5F3EE);      // page background
  static const card = Colors.white;
  static const border = Color(0xFFE2DED5);
  static const ink = Color(0xFF1C2422);        // main text
  static const muted = Color(0xFF66706C);      // secondary text
  static const faint = Color(0xFF9AA19E);

  static const good = Color(0xFF2E7D4F);
  static const warn = Color(0xFFB7791F);
  static const bad = Color(0xFFC0392B);
  static const info = Color(0xFF2563A6);

  // top-bar colour of each portal
  static const collector = brand;
  static const supervisor = Color(0xFFA0522D);
  static const finance = Color(0xFF1E6B45);
  static const owner = Color(0xFF263238);
  static const hr = Color(0xFF5B3E8F);
  static const tech = Color(0xFF1A237E);
  static const selfService = Color(0xFF37474F);

  static Color forRole(String role) {
    switch (role) {
      case 'collector':
        return collector;
      case 'supervisor':
        return supervisor;
      case 'finance':
        return finance;
      case 'owner':
        return owner;
      case 'hr':
        return hr;
      case 'tech':
        return tech;
      default:
        return brand;
    }
  }
}

/// Spacing scale (multiples of 4) and radii.
class Gap {
  Gap._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const radius = 12.0;
  static const radiusSm = 8.0;
}

class AppTheme {
  AppTheme._();

  static const fontFamily = 'IBMPlexSansArabic';

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      primary: AppColors.brand,
      surface: AppColors.card,
      error: AppColors.bad,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: fontFamily);
    final text = base.textTheme.apply(bodyColor: AppColors.ink, displayColor: AppColors.ink);
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gap.radiusSm));
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.paper,
      textTheme: text.copyWith(
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.5),
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: AppColors.brand,
        foregroundColor: Colors.white,
        centerTitle: false,
        titleTextStyle: TextStyle(fontFamily: fontFamily, fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
      ),
      cardTheme: CardThemeData(
        color: AppColors.card,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: Gap.xs),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Gap.radius),
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      dividerTheme: const DividerThemeData(color: AppColors.border, space: 1, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(Gap.radiusSm),
            borderSide: const BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Gap.radiusSm),
            borderSide: const BorderSide(color: AppColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Gap.radiusSm),
            borderSide: const BorderSide(color: AppColors.brand, width: 1.6)),
        labelStyle: const TextStyle(color: AppColors.muted),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.brand,
          foregroundColor: Colors.white,
          minimumSize: const Size(48, 48),
          elevation: 0,
          shape: shape,
          textStyle: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600, fontSize: 15),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48), shape: shape,
            textStyle: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600, fontSize: 15)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.brand,
          minimumSize: const Size(48, 48),
          shape: shape,
          side: const BorderSide(color: AppColors.border),
          textStyle: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.brand,
            textStyle: const TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600)),
      ),
      tabBarTheme: const TabBarThemeData(
        labelStyle: TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w600, fontSize: 14),
        unselectedLabelStyle: TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w500, fontSize: 14),
        dividerColor: Colors.transparent,
      ),
      chipTheme: base.chipTheme.copyWith(
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        labelStyle: const TextStyle(fontFamily: fontFamily, fontSize: 13, color: AppColors.ink),
      ),
      listTileTheme: const ListTileThemeData(iconColor: AppColors.muted, contentPadding: EdgeInsets.symmetric(horizontal: Gap.lg)),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Gap.radius)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: AppColors.brand.withValues(alpha: 0.12),
        labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontFamily: fontFamily, fontSize: 12, fontWeight: FontWeight.w600)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: AppColors.brand, foregroundColor: Colors.white),
    );
  }
}

/// A white card with the standard border and padding.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? accent;          // a coloured strip on the start side for status cards
  final VoidCallback? onTap;
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(Gap.lg), this.accent, this.onTap});

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: accent == null
            ? content
            : IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(width: 4, color: accent),
                  Expanded(child: content),
                ]),
              ),
      ),
    );
  }
}

/// Status levels used across the app.
enum Tone { good, warn, bad, info, neutral }

Color toneColor(Tone t) {
  switch (t) {
    case Tone.good:
      return AppColors.good;
    case Tone.warn:
      return AppColors.warn;
    case Tone.bad:
      return AppColors.bad;
    case Tone.info:
      return AppColors.info;
    case Tone.neutral:
      return AppColors.muted;
  }
}

/// Banner for an important message (a notice, a warning, a blocked action).
class NoticeBanner extends StatelessWidget {
  final String title;
  final String? message;
  final Tone tone;
  final IconData? icon;
  final Widget? action;
  const NoticeBanner({super.key, required this.title, this.message, this.tone = Tone.info, this.icon, this.action});

  @override
  Widget build(BuildContext context) {
    final c = toneColor(tone);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Gap.radius),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon ?? _icon(tone), color: c),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: c)),
            if (message != null) ...[
              const SizedBox(height: 2),
              Text(message!, style: const TextStyle(color: AppColors.ink)),
            ],
            if (action != null) ...[const SizedBox(height: Gap.sm), action!],
          ]),
        ),
      ]),
    );
  }

  static IconData _icon(Tone t) {
    switch (t) {
      case Tone.good:
        return Icons.check_circle;
      case Tone.warn:
        return Icons.warning_amber_rounded;
      case Tone.bad:
        return Icons.error;
      case Tone.info:
        return Icons.info;
      case Tone.neutral:
        return Icons.notes;
    }
  }
}

/// Shown when a list is empty: an icon, one line of what it means and (optionally) what to do.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  const EmptyState({super.key, this.icon = Icons.inbox_outlined, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 44, color: AppColors.faint),
          const SizedBox(height: Gap.md),
          Text(title, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.ink)),
          if (message != null) ...[
            const SizedBox(height: Gap.xs),
            Text(message!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
          ],
          if (action != null) ...[const SizedBox(height: Gap.lg), action!],
        ]),
      ),
    );
  }
}

/// Standard portal AppBar: the portal colour, title, actions, optional tab bar.
PreferredSizeWidget portalAppBar({
  required String title,
  required Color color,
  List<Widget> actions = const [],
  PreferredSizeWidget? bottom,
  String? subtitle,
}) {
  return AppBar(
    backgroundColor: color,
    foregroundColor: Colors.white,
    title: subtitle == null
        ? Text(title)
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title),
            Text(subtitle, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Colors.white70)),
          ]),
    actions: actions,
    bottom: bottom,
  );
}
