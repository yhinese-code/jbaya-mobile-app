import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import 'cc_widgets.dart';

/// Send directives to one employee, all collectors, all supervisors, or everyone. Urgent ones pop up on their phone.
class MessagesTab extends StatefulWidget {
  const MessagesTab({super.key});

  @override
  State<MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends State<MessagesTab> {
  List<Map<String, dynamic>> _staff = [];
  List<Map<String, dynamic>> _sent = [];
  String _audience = 'all';
  String? _employee;
  bool _urgent = false;
  final _body = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final res = await Future.wait([ApiClient.instance.get('/command/live'), ApiClient.instance.get('/command/messages')]);
      if (!mounted) return;
      setState(() {
        _staff = (res[0] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _sent = (res[1] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _send() async {
    if (_body.text.trim().length < 2) {
      setState(() => _error = 'اكتب نص الرسالة');
      return;
    }
    if (_audience == 'one' && _employee == null) {
      setState(() => _error = 'اختر الموظف');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ApiClient.instance.post('/command/messages', {
        'audience': _audience,
        'employee_code': _audience == 'one' ? _employee : null,
        'body': _body.text.trim(),
        'priority': _urgent ? 'urgent' : 'normal',
      });
      if (!mounted) return;
      _body.clear();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إرسال الرسالة')));
      _load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _audienceLabel(Map<String, dynamic> m) => switch (m['audience']) {
        'all' => 'الجميع',
        'collectors' => 'كل الجباة',
        'supervisors' => 'كل المشرفين',
        _ => '${m['recipient_code'] ?? ''}',
      };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final compose = _composer();
      final history = _history();
      if (c.maxWidth >= 1000) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 460, child: compose),
              const SizedBox(width: 16),
              Expanded(child: history),
            ],
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [SizedBox(height: 460, child: compose), const SizedBox(height: 16), SizedBox(height: 500, child: history)],
      );
    });
  }

  Widget _composer() {
    return CCPanel(
      title: 'إرسال توجيه',
      child: ListView(
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('الجميع')),
              ButtonSegment(value: 'collectors', label: Text('الجباة')),
              ButtonSegment(value: 'supervisors', label: Text('المشرفون')),
              ButtonSegment(value: 'one', label: Text('موظف')),
            ],
            selected: {_audience},
            onSelectionChanged: (s) => setState(() => _audience = s.first),
          ),
          if (_audience == 'one') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _employee,
              isExpanded: true,
              dropdownColor: CC.panelHigh,
              decoration: const InputDecoration(labelText: 'الموظف', border: OutlineInputBorder(), isDense: true),
              items: _staff
                  .map((s) => DropdownMenuItem(value: s['employee_code'] as String, child: Text('${s['employee_code']} - ${s['full_name']}')))
                  .toList(),
              onChanged: (v) => setState(() => _employee = v),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            maxLines: 5,
            maxLength: 1000,
            decoration: const InputDecoration(hintText: 'نص التوجيه...', border: OutlineInputBorder()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _urgent,
            onChanged: (v) => setState(() => _urgent = v),
            title: const Text('عاجل'),
            subtitle: const Text('يظهر فوراً كنافذة على هاتف الموظف', style: TextStyle(fontSize: 12, color: CC.muted)),
          ),
          if (_error != null) Text(_error!, style: const TextStyle(color: CC.danger)),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _sending ? null : _send,
            icon: const Icon(Icons.send),
            label: const Text('إرسال'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _urgent ? CC.danger : CC.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _history() {
    return CCPanel(
      title: 'الرسائل المرسلة',
      padding: EdgeInsets.zero,
      actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh, size: 18))],
      child: _sent.isEmpty
          ? const Center(child: Text('لم تُرسل رسائل بعد', style: TextStyle(color: CC.muted)))
          : ListView.separated(
              itemCount: _sent.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final m = _sent[i];
                final urgent = m['priority'] == 'urgent';
                return ListTile(
                  leading: Icon(urgent ? Icons.campaign : Icons.mail, color: urgent ? CC.danger : CC.accent),
                  title: Text('${m['body']}', style: const TextStyle(color: CC.text)),
                  subtitle: Text('إلى: ${_audienceLabel(m)} | ${timeAgo(m['created_at'] as String?)} | قُرئت ${m['reads']} مرة',
                      style: const TextStyle(color: CC.muted, fontSize: 12)),
                );
              },
            ),
    );
  }
}
