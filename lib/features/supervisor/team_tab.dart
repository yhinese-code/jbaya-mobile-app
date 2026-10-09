import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../shared/ui.dart';

/// Team activity today. Deliberately shows counts only (no money) so the cash reconciliation stays blind.
class TeamTab extends StatefulWidget {
  const TeamTab({super.key});

  @override
  State<TeamTab> createState() => _TeamTabState();
}

class _TeamTabState extends State<TeamTab> {
  List<Map<String, dynamic>> _team = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await ApiClient.instance.get('/supervisor/team');
      if (!mounted) return;
      setState(() {
        _team = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _ago(String? iso) {
    final t = DateTime.tryParse(iso ?? '');
    if (t == null) return 'لا يوجد نشاط';
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 1) return 'الآن';
    if (d.inMinutes < 60) return 'قبل ${d.inMinutes} دقيقة';
    if (d.inHours < 24) return 'قبل ${d.inHours} ساعة';
    return 'قبل ${d.inDays} يوم';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return EmptyState(
        icon: Icons.cloud_off,
        title: 'تعذر تحميل الفريق',
        message: _error,
        action: OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
      );
    }
    if (_team.isEmpty) {
      return const EmptyState(
        icon: Icons.groups_outlined,
        title: 'لا يوجد جباة ضمن فريقك',
        message: 'يضيف قسم الموارد البشرية الجباة إلى فريقك',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.all(Gap.md),
        itemCount: _team.length,
        itemBuilder: (context, i) {
          final t = _team[i];
          final sos = (t['open_sos'] as num? ?? 0) > 0;
          final master = (t['master_uses_today'] as num? ?? 0);
          return AppCard(
            accent: sos ? AppColors.bad : null,
            padding: const EdgeInsets.all(Gap.md),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: sos ? AppColors.bad : AppColors.brand.withValues(alpha: 0.10),
                        child: Icon(sos ? Icons.sos : Icons.person, color: sos ? Colors.white : AppColors.brand),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${t['employee_code']} - ${t['full_name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            Text('${t['sector_name'] ?? ''} | آخر نشاط: ${_ago(t['last_activity'] as String?)}',
                                style: const TextStyle(fontSize: 12, color: AppColors.muted),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Gap.sm),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (t['on_leave'] == true)
                        const StatusChip('في إجازة', AppColors.info)
                      else if (t['checked_in_at'] != null)
                        StatusChip(
                            'حضور ${formatTime(t['checked_in_at'])}${(t['late_minutes'] as num? ?? 0) > 0 ? ' (تأخير ${t['late_minutes']} د)' : ''}',
                            (t['late_minutes'] as num? ?? 0) > 0 ? AppColors.warn : AppColors.good)
                      else
                        const StatusChip('لم يسجل الحضور', AppColors.bad),
                      _chip('وصولات اليوم', t['receipts_today'], AppColors.good),
                      _chip('تسجيلات اليوم', t['registrations_today'], AppColors.info),
                      _chip('بانتظار التسليم', t['open_receipts'], AppColors.brand),
                      if ((t['bills_in_review'] as num? ?? 0) > 0) _chip('قيد المراجعة', t['bills_in_review'], AppColors.warn),
                      if (master > 0) _chip('الرمز الرئيسي', master, master >= 3 ? AppColors.bad : AppColors.warn),
                    ],
                  ),
                ],
              ),
          );
        },
      ),
    );
  }

  Widget _chip(String label, dynamic value, Color color) => StatusChip('$label: $value', color);
}
