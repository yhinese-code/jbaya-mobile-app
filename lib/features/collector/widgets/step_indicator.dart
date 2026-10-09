import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// "1 ── 2 ── 3" header for multi-step field flows. [current] is 1-based; steps before it show a check mark.
class StepIndicator extends StatelessWidget {
  final List<String> labels;
  final int current;
  final Color color;
  const StepIndicator({super.key, required this.labels, required this.current, this.color = AppColors.collector});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (int i = 0; i < labels.length; i++) {
      final n = i + 1;
      final done = n < current;
      final active = n == current;
      children.add(Expanded(
        child: Column(children: [
          Row(children: [
            Expanded(child: i == 0 ? const SizedBox() : Container(height: 2, color: n <= current ? color : AppColors.border)),
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done || active ? color : Colors.white,
                border: Border.all(color: done || active ? color : AppColors.border, width: 2),
              ),
              child: done
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : Text('$n',
                      style: TextStyle(fontWeight: FontWeight.w700, color: active ? Colors.white : AppColors.muted)),
            ),
            Expanded(
                child: i == labels.length - 1
                    ? const SizedBox()
                    : Container(height: 2, color: n < current ? color : AppColors.border)),
          ]),
          const SizedBox(height: Gap.xs),
          Text(
            labels[i],
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? AppColors.ink : AppColors.muted,
            ),
          ),
        ]),
      ));
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

/// The bottom area holding a screen's one primary action (kept above the keyboard / system bar).
class BottomActionBar extends StatelessWidget {
  final List<Widget> children;
  const BottomActionBar({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.md),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-width primary button with a spinner while [busy].
class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;
  final Color? color;
  const PrimaryButton({super.key, required this.label, this.icon, this.onPressed, this.busy = false, this.color});

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(52),
      backgroundColor: color,
      textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 16, fontWeight: FontWeight.w700),
    );
    final child = busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
        : Text(label, textAlign: TextAlign.center);
    if (icon == null || busy) return FilledButton(onPressed: busy ? null : onPressed, style: style, child: child);
    return FilledButton.icon(onPressed: onPressed, style: style, icon: Icon(icon), label: child);
  }
}
