import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/theme.dart';

/// Envelope icon with an unread badge. Checks for Command messages every 60 s;
/// a new URGENT message pops up immediately.
class InboxButton extends StatefulWidget {
  const InboxButton({super.key});

  @override
  State<InboxButton> createState() => _InboxButtonState();
}

class _InboxButtonState extends State<InboxButton> {
  List<Map<String, dynamic>> _messages = [];
  int _unread = 0;
  Timer? _timer;
  final Set<int> _announced = {};

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await ApiClient.instance.get('/messages/inbox');
      if (!mounted) return;
      final list = (res['messages'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      setState(() {
        _messages = list;
        _unread = (res['unread'] as num?)?.toInt() ?? 0;
      });
      final urgent = list.where((m) => m['priority'] == 'urgent' && m['is_read'] != true && !_announced.contains(m['id'])).toList();
      if (urgent.isNotEmpty) {
        _announced.addAll(urgent.map((m) => m['id'] as int));
        _showUrgent(urgent.first);
      }
    } on ApiException catch (_) {
      // silent: the badge just doesn't update
    }
  }

  Future<void> _markRead(Map<String, dynamic> m) async {
    if (m['is_read'] == true) return;
    try {
      await ApiClient.instance.post('/messages/${m['id']}/read');
      if (!mounted) return;
      setState(() {
        m['is_read'] = true;
        _unread = _messages.where((x) => x['is_read'] != true).length;
      });
    } on ApiException catch (_) {}
  }

  void _showUrgent(Map<String, dynamic> m) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.campaign, color: AppColors.bad, size: 40),
        title: const Text('توجيه عاجل من القيادة'),
        content: Text('${m['body']}', style: const TextStyle(fontSize: 18)),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _markRead(m);
            },
            child: const Text('تم الاستلام'),
          ),
        ],
      ),
    );
  }

  void _open() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('رسائل القيادة', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
              const Divider(height: 1),
              if (_messages.isEmpty)
                const EmptyState(icon: Icons.mark_email_read_outlined, title: 'لا توجد رسائل', message: 'رسائل القيادة وتوجيهاتها تظهر هنا')
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _messages.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final m = _messages[i];
                      final t = DateTime.tryParse('${m['created_at']}')?.toLocal();
                      final urgent = m['priority'] == 'urgent';
                      return ListTile(
                        leading: Icon(
                          urgent ? Icons.campaign : Icons.mail,
                          color: urgent ? AppColors.bad : (m['is_read'] == true ? AppColors.muted : AppColors.info),
                        ),
                        title: Text('${m['body']}',
                            style: TextStyle(fontWeight: m['is_read'] == true ? FontWeight.normal : FontWeight.bold)),
                        subtitle: Text('${m['sender_name']}'
                            '${t == null ? '' : ' | ${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'}'),
                        onTap: () => _markRead(m),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    ).then((_) {
      for (final m in List<Map<String, dynamic>>.from(_messages)) {
        _markRead(m);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'الرسائل',
      onPressed: _open,
      icon: Badge(
        isLabelVisible: _unread > 0,
        label: Text('$_unread'),
        child: const Icon(Icons.mail),
      ),
    );
  }
}
