import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/theme.dart';

/// Today's receipts + any receipt not yet handed over to the supervisor.
class ReceiptsScreen extends StatefulWidget {
  const ReceiptsScreen({super.key});

  @override
  State<ReceiptsScreen> createState() => ReceiptsScreenState();
}

class ReceiptsScreenState extends State<ReceiptsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

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
      final res = await ApiClient.instance.get('/collector/receipts');
      if (!mounted) return;
      setState(() => _items = (res as List).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return EmptyState(
        icon: Icons.cloud_off,
        title: 'تعذر تحميل الوصولات',
        message: _error,
        action: OutlinedButton.icon(onPressed: reload, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: reload,
        child: ListView(children: const [
          SizedBox(height: 60),
          EmptyState(icon: Icons.receipt_long_outlined, title: 'لا توجد وصولات اليوم'),
        ]),
      );
    }
    final notHanded = _items.where((r) => r['handed_over'] != true).toList();
    final total = notHanded.fold<double>(0, (sum, r) => sum + (asNum(r['total_amount']) ?? 0));
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl),
        children: [
          AppCard(
            accent: AppColors.brand,
            child: Row(children: [
              const Icon(Icons.account_balance_wallet_outlined, color: AppColors.brand, size: 28),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('بانتظار التسليم للمشرف: ${notHanded.length} وصل', style: const TextStyle(color: AppColors.muted)),
                  Text(formatIqd(total), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: Gap.xs),
          ..._items.map((r) {
            final handed = r['handed_over'] == true;
            final master = r['verification_method'] == 'master_code';
            return AppCard(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg, vertical: Gap.md),
              child: Row(children: [
                Icon(handed ? Icons.check_circle : Icons.receipt_long_outlined,
                    color: handed ? AppColors.good : AppColors.warn),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${r['citizen_name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      '${r['receipt_no']}  ·  ${r['property_code']}  ·  ${formatTime(r['issued_at'])}'
                      '${master ? '  ·  الرمز الرئيسي' : ''}${handed ? '  ·  سُلّم' : ''}',
                      style: const TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                  ]),
                ),
                const SizedBox(width: Gap.sm),
                Text(formatIqd(asNum(r['total_amount'])), style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            );
          }),
        ],
      ),
    );
  }
}
