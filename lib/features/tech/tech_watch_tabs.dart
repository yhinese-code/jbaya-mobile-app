import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../shared/ui.dart';
import 'tech_common.dart';

// ================================================================ WhatsApp

Color _waStatusColor(String s) {
  switch (s) {
    case 'sent':
      return Colors.green.shade700;
    case 'failed':
      return Colors.red.shade700;
    default:
      return Colors.blueGrey;
  }
}

const Map<String, String> _waStatusLabels = {'sent': 'أُرسلت', 'failed': 'فشلت', 'console': 'تجريبي'};

/// WhatsApp gateway: mode, approved templates, monthly volume and cost, and the last 100 messages.
class TechWhatsAppTab extends StatelessWidget {
  const TechWhatsAppTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/tech/whatsapp',
      builder: (context, data, reload) {
        final d = data as Map;
        final live = d['mode'] == 'live';
        final configured = d['configured'] == true;
        final templates = ((d['templates'] as List?) ?? const []).cast<Map>();
        final months = ((d['months'] as List?) ?? const []).cast<Map>();
        final log = ((d['log'] as List?) ?? const []).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Column(children: [
                  ListTile(
                    leading: Icon(Icons.chat, color: live ? Colors.green : Colors.orange),
                    title: const Text('وضع الإرسال'),
                    subtitle: Text(live ? 'إرسال فعلي' : 'تجريبي (لا يُرسل، تُطبع الرسائل في الخادم)'),
                  ),
                  ListTile(
                    leading: Icon(configured ? Icons.link : Icons.link_off, color: configured ? Colors.green : Colors.red),
                    title: const Text('الربط بحساب ميتا'),
                    subtitle: Text(configured ? 'مربوط (يوجد رمز الوصول ورقم الإرسال)' : 'غير مربوط: لا يوجد رمز وصول أو رقم إرسال'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.attach_money, color: Colors.indigo),
                    title: const Text('كلفة الرسالة'),
                    subtitle: Text('${txt(d['cost_per_message_usd'])} دولار'),
                  ),
                ]),
              ),
              if (live && !configured)
                Card(
                  color: Colors.red.withValues(alpha: 0.08),
                  child: const ListTile(
                    leading: Icon(Icons.warning, color: Colors.red),
                    title: Text('الوضع «إرسال فعلي» لكن الحساب غير مربوط، ستفشل الرسائل'),
                  ),
                ),
              const SectionTitle('القوالب المعتمدة'),
              const Text(
                'هذا هو النص المعتمد من ميتا حرفياً. تغيير الصياغة يحتاج قالباً جديداً تعتمده ميتا أولاً، '
                'ثم تغيير اسم القالب من تبويب الإعدادات (مجموعة واتساب).',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 6),
              for (final t in templates)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        SelectableText(txt(t['name']), style: const TextStyle(fontWeight: FontWeight.bold)),
                        StatusChip(txt(t['category']), kTechColor),
                        Text('(${txt(t['key'])})', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      ]),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
                        ),
                        child: SelectableText(txt(t['text'])),
                      ),
                    ]),
                  ),
                ),
              const SectionTitle('الحجم الشهري والكلفة'),
              if (months.isEmpty)
                const EmptyNote('لا توجد رسائل بعد')
              else
                Card(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columnSpacing: 20,
                      columns: const [
                        DataColumn(label: Text('الشهر')),
                        DataColumn(label: Text('أُرسلت'), numeric: true),
                        DataColumn(label: Text('فشلت'), numeric: true),
                        DataColumn(label: Text('تجريبي'), numeric: true),
                        DataColumn(label: Text('الكلفة \$'), numeric: true),
                      ],
                      rows: [
                        for (final m in months)
                          DataRow(cells: [
                            DataCell(Text(txt(m['month']))),
                            DataCell(Text(formatNumber(asNum(m['sent'])))),
                            DataCell(Text(formatNumber(asNum(m['failed'])),
                                style: TextStyle(color: toInt(m['failed']) > 0 ? Colors.red : null))),
                            DataCell(Text(formatNumber(asNum(m['console'])))),
                            DataCell(Text(txt(m['cost_usd']))),
                          ]),
                      ],
                    ),
                  ),
                ),
              SectionTitle('آخر الرسائل (${log.length})'),
              if (log.isEmpty) const EmptyNote('لا توجد رسائل'),
              for (final m in log)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text('${txt(m['phone'])}  •  ${txt(m['template'])}',
                              textDirection: TextDirection.ltr, textAlign: TextAlign.right),
                        ),
                        const SizedBox(width: 6),
                        StatusChip(_waStatusLabels[m['status']] ?? txt(m['status']), _waStatusColor(txt(m['status'], ''))),
                      ]),
                      Text(shortTs(m['created_at']), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      if (m['error'] != null)
                        Text(txt(m['error']), style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
                    ]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ fraud watch

const Map<String, String> _eventLabels = {
  'fast_otp': 'رمز أُدخل بسرعة',
  'phone_flags': 'رقم مشبوه',
  'phone_blocked': 'رُفض لتجاوز حد الرقم',
  'employee_phone': 'رقم موظف كمواطن',
  'device_sharing': 'مشاركة جهاز',
  'master_code': 'استخدام الرمز الرئيسي',
};

const Map<String, String> _callbackLabels = {'denied': 'أنكر المواطن الدفع', 'wrong_amount': 'المبلغ مختلف'};

/// Patterns that look like a collector confirming payments himself.
class TechFraudTab extends StatefulWidget {
  const TechFraudTab({super.key});

  @override
  State<TechFraudTab> createState() => _TechFraudTabState();
}

class _TechFraudTabState extends State<TechFraudTab> {
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 7, label: Text('7 أيام')),
            ButtonSegment(value: 30, label: Text('30 يوماً')),
            ButtonSegment(value: 90, label: Text('90 يوماً')),
          ],
          selected: {_days},
          onSelectionChanged: (s) => setState(() => _days = s.first),
        ),
      ),
      Expanded(
        child: ApiView(
          path: '/tech/fraud?days=$_days',
          builder: (context, data, reload) {
            final d = data as Map;
            final numbers = ((d['numbers'] as List?) ?? const []).cast<Map>();
            final people = ((d['people'] as List?) ?? const []).cast<Map>();
            final callbacks = ((d['callbacks'] as List?) ?? const []).cast<Map>();
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  SectionTitle('أرقام مواطنين على منازل كثيرة (${numbers.length})'),
                  if (numbers.isEmpty) const EmptyNote('لا توجد أرقام مشبوهة'),
                  for (final n in numbers)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(txt(n['phone']), textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.bold)),
                          InfoLine(
                            Icons.home_work,
                            'منازل: ${toInt(n['houses'])}  •  جباة: ${toInt(n['collectors'])}  •  قواطع: ${toInt(n['sectors'])}',
                            color: toInt(n['sectors']) > 1 ? Colors.red.shade700 : null,
                          ),
                          InfoLine(Icons.person, 'سجّلها: ${txt(n['registered_by'])}'),
                        ]),
                      ),
                    ),
                  SectionTitle('أشخاص بأحداث مشبوهة (${people.length})'),
                  if (people.isEmpty) const EmptyNote('لا توجد أحداث في هذه المدة'),
                  for (final p in people)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${txt(p['employee_code'])} - ${txt(p['full_name'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          Wrap(spacing: 6, runSpacing: 4, children: [
                            for (final e in _eventLabels.entries)
                              if (toInt(p[e.key]) > 0) StatusChip('${e.value}: ${toInt(p[e.key])}', Colors.deepOrange),
                          ]),
                        ]),
                      ),
                    ),
                  SectionTitle('مشاكل الاتصال العشوائي (${callbacks.length})'),
                  if (callbacks.isEmpty) const EmptyNote('لا توجد مشاكل'),
                  if (callbacks.isNotEmpty)
                    Card(
                      child: Column(children: [
                        for (final c in callbacks)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              c['status'] == 'denied' ? Icons.phone_disabled : Icons.money_off,
                              color: Colors.red.shade700,
                            ),
                            title: Text('${txt(c['employee_code'])}: ${_callbackLabels[c['status']] ?? txt(c['status'])}'),
                            trailing: Text('${toInt(c['n'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                      ]),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ================================================================ audit log

/// The tamper-evident audit log, filterable by employee and action.
class TechAuditTab extends StatefulWidget {
  const TechAuditTab({super.key});

  @override
  State<TechAuditTab> createState() => _TechAuditTabState();
}

class _TechAuditTabState extends State<TechAuditTab> {
  final _actorC = TextEditingController();
  final _actionC = TextEditingController();
  String _actor = '';
  String _action = '';
  bool _verifying = false;

  @override
  void dispose() {
    _actorC.dispose();
    _actionC.dispose();
    super.dispose();
  }

  void _apply() => setState(() {
        _actor = _actorC.text.trim();
        _action = _actionC.text.trim();
      });

  Future<void> _verify() async {
    setState(() => _verifying = true);
    final r = await runApi(context, () => ApiClient.instance.get('/tech/audit/verify'));
    if (!mounted) return;
    setState(() => _verifying = false);
    if (r is! Map) return;
    final valid = r['valid'] == true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(valid ? Icons.verified : Icons.dangerous, color: valid ? Colors.green : Colors.red, size: 40),
        title: Text(valid ? 'السجل سليم' : 'تم اكتشاف تعديل في السجل'),
        content: Text(valid
            ? 'فُحص ${toInt(r['checked'])} سجلاً مترابطاً ولم يُعدَّل أي منها.'
            : 'السلسلة مكسورة عند السجل رقم ${txt(r['broken_at_id'])} (بعد ${toInt(r['checked'])} سجلاً سليماً).'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = '/tech/audit${buildQuery({'actor': _actor, 'action': _action, 'limit': '200'})}';
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _actorC,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _apply(),
              decoration: const InputDecoration(labelText: 'رقم الموظف', border: OutlineInputBorder(), isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _actionC,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _apply(),
              decoration: const InputDecoration(labelText: 'الإجراء (جزء منه)', border: OutlineInputBorder(), isDense: true),
            ),
          ),
          IconButton(tooltip: 'بحث', onPressed: _apply, icon: const Icon(Icons.search)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: _verifying ? null : _verify,
            icon: const Icon(Icons.link),
            label: Text(_verifying ? 'جاري الفحص...' : 'فحص سلامة السجل'),
          ),
        ),
      ),
      Expanded(
        child: ApiView(
          path: path,
          builder: (context, data, reload) {
            final rows = ((data as List?) ?? const []).cast<Map>();
            return RefreshIndicator(
              onRefresh: reload,
              child: rows.isEmpty
                  ? ListView(children: const [EmptyNote('لا توجد سجلات مطابقة')])
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: rows.length,
                      itemBuilder: (context, i) => _auditRow(rows[i]),
                    ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _auditRow(Map r) {
    final role = techRoleLabels[r['role']] ?? txt(r['role'], '');
    final who = r['employee_code'] == null ? 'النظام' : '${r['employee_code']}${role.isEmpty ? '' : ' ($role)'}';
    final entity = r['entity'] == null ? '' : '  •  ${r['entity']}${r['entity_id'] != null ? ' #${r['entity_id']}' : ''}';
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: Text(txt(r['action']), textDirection: TextDirection.ltr, textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${shortTs(r['created_at'])}  •  $who$entity'),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
            child: SelectableText(
              prettyJson(r['details']),
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          Text('رقم السجل: ${txt(r['id'])}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
        ],
      ),
    );
  }
}
