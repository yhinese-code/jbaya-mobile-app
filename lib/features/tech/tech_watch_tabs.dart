import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../shared/ui.dart';
import 'tech_common.dart';

// ================================================================ WhatsApp

Color _waStatusColor(String s) {
  switch (s) {
    case 'sent':
      return AppColors.good;
    case 'failed':
      return AppColors.bad;
    case 'free':
      return AppColors.info;
    default:
      return AppColors.muted;
  }
}

const Map<String, String> _waStatusLabels = {'sent': 'أُرسلت', 'failed': 'فشلت', 'console': 'تجريبي', 'free': 'مجانية'};

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
            padding: const EdgeInsets.all(Gap.md),
            children: [
              Card(
                child: Column(children: [
                  ListTile(
                    leading: Icon(Icons.chat, color: live ? AppColors.good : AppColors.warn),
                    title: const Text('وضع الإرسال'),
                    subtitle: Text(live ? 'إرسال فعلي' : 'تجريبي (لا يُرسل، تُطبع الرسائل في الخادم)'),
                  ),
                  ListTile(
                    leading: Icon(configured ? Icons.link : Icons.link_off, color: configured ? AppColors.good : AppColors.bad),
                    title: const Text('الربط بحساب ميتا'),
                    subtitle: Text(configured ? 'مربوط (يوجد رمز الوصول ورقم الإرسال)' : 'غير مربوط: لا يوجد رمز وصول أو رقم إرسال'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.attach_money, color: AppColors.brand),
                    title: const Text('كلفة الرسالة'),
                    subtitle: Text('${txt(d['cost_per_message_usd'])} دولار للرسالة المدفوعة'),
                  ),
                  const ListTile(
                    leading: Icon(Icons.money_off, color: AppColors.good),
                    title: Text('الرسائل المجانية'),
                    subtitle: Text('بلا كلفة: ردود على رسالة المواطن خلال نافذة الـ24 ساعة لا تُحتسب في الكلفة'),
                  ),
                ]),
              ),
              if (live && !configured)
                const NoticeBanner(
                  tone: Tone.bad,
                  title: 'الوضع «إرسال فعلي» لكن الحساب غير مربوط',
                  message: 'ستفشل الرسائل حتى يُضاف رمز الوصول ورقم الإرسال.',
                ),
              if (!live) _SimulateInboundCard(onDone: reload),
              const SectionTitle('القوالب المعتمدة'),
              const Text(
                'هذا هو النص المعتمد من ميتا حرفياً. تغيير الصياغة يحتاج قالباً جديداً تعتمده ميتا أولاً، '
                'ثم تغيير اسم القالب من تبويب الإعدادات (مجموعة واتساب).',
                style: TextStyle(color: AppColors.muted, fontSize: 13),
              ),
              const SizedBox(height: 6),
              for (final t in templates)
                AppCard(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        SelectableText(txt(t['name']), style: const TextStyle(fontWeight: FontWeight.bold)),
                        StatusChip(txt(t['category']), kTechColor),
                        Text('(${txt(t['key'])})', style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                      ]),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.muted.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.muted.withValues(alpha: 0.3)),
                        ),
                        child: SelectableText(txt(t['text'])),
                      ),
                    ]),
                ),
              const SectionTitle('الحجم الشهري والكلفة'),
              if (months.isEmpty)
                const EmptyNote('لا توجد رسائل بعد')
              else
                Card(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowColor: WidgetStateProperty.all(AppColors.paper),
                      headingTextStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontWeight: FontWeight.w600, color: AppColors.muted, fontSize: 13),
                      dataTextStyle: const TextStyle(fontFamily: AppTheme.fontFamily, color: AppColors.ink, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
                      columnSpacing: 20,
                      columns: const [
                        DataColumn(label: Text('الشهر')),
                        DataColumn(label: Text('أُرسلت'), numeric: true),
                        DataColumn(label: Text('فشلت'), numeric: true),
                        DataColumn(label: Text('تجريبي'), numeric: true),
                        DataColumn(label: Text('مجانية'), numeric: true),
                        DataColumn(label: Text('الكلفة \$'), numeric: true),
                      ],
                      rows: [
                        for (final m in months)
                          DataRow(cells: [
                            DataCell(Text(txt(m['month']))),
                            DataCell(Text(formatNumber(asNum(m['sent'])))),
                            DataCell(Text(formatNumber(asNum(m['failed'])),
                                style: TextStyle(color: toInt(m['failed']) > 0 ? AppColors.bad : null))),
                            DataCell(Text(formatNumber(asNum(m['console'])))),
                            DataCell(Text(formatNumber(asNum(m['free'])), style: const TextStyle(color: AppColors.good))),
                            DataCell(Text(txt(m['cost_usd']))),
                          ]),
                      ],
                    ),
                  ),
                ),
              if (months.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: Gap.xs),
                  child: Text('الكلفة تُحسب على الرسائل المُرسلة المدفوعة فقط؛ الرسائل المجانية بلا كلفة.',
                      style: TextStyle(color: AppColors.muted, fontSize: 12)),
                ),
              SectionTitle('آخر الرسائل (${log.length})'),
              if (log.isEmpty) const EmptyNote('لا توجد رسائل'),
              for (final m in log)
                AppCard(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text('${txt(m['phone'])}  •  ${txt(m['template'])}',
                              textDirection: TextDirection.ltr, textAlign: TextAlign.right),
                        ),
                        const SizedBox(width: 6),
                        StatusChip(_waStatusLabels[m['status']] ?? txt(m['status']), _waStatusColor(txt(m['status'], ''))),
                      ]),
                      Text(shortTs(m['created_at']), style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                      if (m['error'] != null)
                        Text(txt(m['error']), style: const TextStyle(color: AppColors.bad, fontSize: 12)),
                    ]),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// TESTING ONLY (console mode): pretend a citizen sent a WhatsApp message, then show what the system did with it.
class _SimulateInboundCard extends StatefulWidget {
  final Future<void> Function() onDone;
  const _SimulateInboundCard({required this.onDone});

  @override
  State<_SimulateInboundCard> createState() => _SimulateInboundCardState();
}

class _SimulateInboundCardState extends State<_SimulateInboundCard> {
  final _phone = TextEditingController();
  final _text = TextEditingController();
  bool _busy = false;
  List<dynamic>? _handled;
  bool _duplicate = false;

  @override
  void dispose() {
    _phone.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final phone = latinDigits(_phone.text);
    if (phone.isEmpty) {
      showSnack(context, 'أدخل رقم الهاتف', error: true);
      return;
    }
    setState(() => _busy = true);
    final r = await runApi(context, () => ApiClient.instance.post('/whatsapp/simulate-inbound', {'phone': phone, 'text': _text.text.trim()}));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r is Map) {
        _duplicate = r['duplicate'] == true;
        _handled = (r['handled'] as List?) ?? const [];
      }
    });
    if (r != null) await widget.onDone();
  }

  String _describe(dynamic h) {
    if (h is Map) {
      if (h['activated'] != null) return 'فُعّل العقار ${h['activated']}';
      if (h['error'] != null) return 'طلب الانتظار #${txt(h['wait'])}: ${txt(h['error'])}';
      if (h['wait'] != null) return 'عولج طلب الانتظار #${txt(h['wait'])}${h['property_code'] != null ? ' للعقار ${h['property_code']}' : ''}';
      return compactJson(h);
    }
    return txt(h);
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      accent: AppColors.info,
      padding: const EdgeInsets.all(Gap.md),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(children: [
          Icon(Icons.science_outlined, color: AppColors.info),
          SizedBox(width: Gap.sm),
          Expanded(child: Text('محاكاة رسالة مواطن (للتجربة)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15))),
        ]),
        const SizedBox(height: Gap.xs),
        const Text('متاحة في الوضع التجريبي فقط: تُعامل الرسالة كأنها وصلت من المواطن عبر واتساب.',
            style: TextStyle(color: AppColors.muted, fontSize: 12)),
        const SizedBox(height: Gap.md),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(labelText: 'رقم هاتف المواطن', hintText: '07XXXXXXXXX', isDense: true),
        ),
        const SizedBox(height: Gap.sm),
        TextField(
          controller: _text,
          maxLength: 500,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'نص الرسالة', isDense: true),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ElevatedButton.icon(
            onPressed: _busy ? null : _send,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send),
            label: const Text('إرسال المحاكاة'),
          ),
        ),
        if (_handled != null) ...[
          const SizedBox(height: Gap.md),
          const Text('ما فعله النظام', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: Gap.xs),
          if (_duplicate)
            const Text('رسالة مكررة؛ لم يُعالج شيء.', style: TextStyle(color: AppColors.muted))
          else if (_handled!.isEmpty)
            const Text('لا شيء: لا توجد طلبات انتظار أو عقارات مرتبطة بهذا الرقم.', style: TextStyle(color: AppColors.muted))
          else
            for (final h in _handled!)
              InfoLine(
                h is Map && h['error'] != null ? Icons.error_outline : Icons.check_circle_outline,
                _describe(h),
                color: h is Map && h['error'] != null ? AppColors.bad : AppColors.good,
              ),
        ],
      ]),
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
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
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
                padding: const EdgeInsets.all(Gap.md),
                children: [
                  SectionTitle('أرقام مواطنين على منازل كثيرة (${numbers.length})'),
                  if (numbers.isEmpty) const EmptyNote('لا توجد أرقام مشبوهة'),
                  for (final n in numbers)
                    AppCard(
                      padding: const EdgeInsets.all(Gap.md),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(txt(n['phone']), textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.bold)),
                          InfoLine(
                            Icons.home_work,
                            'منازل: ${toInt(n['houses'])}  •  جباة: ${toInt(n['collectors'])}  •  قواطع: ${toInt(n['sectors'])}',
                            color: toInt(n['sectors']) > 1 ? AppColors.bad : null,
                          ),
                          InfoLine(Icons.person, 'سجّلها: ${txt(n['registered_by'])}'),
                        ]),
                    ),
                  SectionTitle('أشخاص بأحداث مشبوهة (${people.length})'),
                  if (people.isEmpty) const EmptyNote('لا توجد أحداث في هذه المدة'),
                  for (final p in people)
                    AppCard(
                      padding: const EdgeInsets.all(Gap.md),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${txt(p['employee_code'])} - ${txt(p['full_name'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          Wrap(spacing: 6, runSpacing: 4, children: [
                            for (final e in _eventLabels.entries)
                              if (toInt(p[e.key]) > 0) StatusChip('${e.value}: ${toInt(p[e.key])}', AppColors.warn),
                          ]),
                        ]),
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
                              color: AppColors.bad,
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
        icon: Icon(valid ? Icons.verified : Icons.dangerous, color: valid ? AppColors.good : AppColors.bad, size: 40),
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
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
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
                      padding: const EdgeInsets.all(Gap.md),
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
            decoration: BoxDecoration(color: AppColors.muted.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
            child: SelectableText(
              prettyJson(r['details']),
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          Text('رقم السجل: ${txt(r['id'])}', style: const TextStyle(color: AppColors.muted, fontSize: 11)),
        ],
      ),
    );
  }
}
