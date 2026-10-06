import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../hr/hr_tabs.dart' show currentPeriod, recentPeriods;
import '../shared/ui.dart';
import 'charts.dart';

bool get _canWrite => const ['finance', 'admin'].contains(Session.instance.role);

const _sourceLabels = {
  'receipt': 'وصل',
  'reconciliation': 'مطابقة',
  'resolution': 'تسوية فرق',
  'deposit': 'إيداع',
  'deposit_verified': 'تدقيق إيداع',
  'deposit_rejected': 'رفض إيداع',
  'payroll': 'رواتب',
  'remittance': 'توريد حكومي',
  'journal': 'قيد يدوي',
};

// ================================================================ accounts (trial balance / ledger / income / journal)

class AccountsTab extends StatefulWidget {
  const AccountsTab({super.key});

  @override
  State<AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends State<AccountsTab> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  String? _account;
  int _opened = 0; // forces the ledger to reopen even when the same account is tapped again

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _openAccount(String code) {
    setState(() {
      _account = code;
      _opened++;
    });
    _tabs.animateTo(1);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      TabBar(
        controller: _tabs,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        tabs: const [Tab(text: 'ميزان المراجعة'), Tab(text: 'دفتر الأستاذ'), Tab(text: 'قائمة الدخل'), Tab(text: 'القيود اليدوية')],
      ),
      Expanded(
        child: TabBarView(controller: _tabs, children: [
          _TrialBalance(onOpen: _openAccount),
          _Ledger(key: ValueKey('$_account-$_opened'), initialAccount: _account),
          const _IncomeStatement(),
          const _Journal(),
        ]),
      ),
    ]);
  }
}

class _TrialBalance extends StatefulWidget {
  final ValueChanged<String> onOpen;
  const _TrialBalance({required this.onOpen});

  @override
  State<_TrialBalance> createState() => _TrialBalanceState();
}

class _TrialBalanceState extends State<_TrialBalance> {
  DateTime _asOf = DateTime.now();

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/finance/trial-balance?as_of=${apiDate(_asOf)}',
      builder: (context, d, reload) {
        final rows = (d['accounts'] as List).cast<Map>();
        final balanced = d['balanced'] == true;
        String? lastType;
        final tableRows = <DataRow>[];
        for (final r in rows) {
          if (r['type'] != lastType) {
            lastType = r['type'] as String;
            tableRows.add(DataRow(color: WidgetStateProperty.all(Colors.grey.withValues(alpha: 0.1)), cells: [
              DataCell(Text('${r['type_label']}', style: const TextStyle(fontWeight: FontWeight.bold))),
              const DataCell(Text('')), const DataCell(Text('')), const DataCell(Text('')),
            ]));
          }
          final bal = (asNum(r['balance']) ?? 0).toDouble();
          tableRows.add(DataRow(
            onSelectChanged: (_) => widget.onOpen('${r['code']}'),
            cells: [
              DataCell(Text('${r['code']}  ${r['name']}')),
              DataCell(Text(formatNumber(asNum(r['debit'])))),
              DataCell(Text(formatNumber(asNum(r['credit'])))),
              DataCell(Text(formatNumber(bal), style: TextStyle(fontWeight: FontWeight.bold, color: bal < 0 ? Colors.red : null))),
            ],
          ));
        }
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text('حتى تاريخ ${apiDate(_asOf)}'),
                  onPressed: () async {
                    final p = await showDatePicker(context: context, initialDate: _asOf, firstDate: DateTime(2025), lastDate: DateTime.now());
                    if (p != null) setState(() => _asOf = p);
                  },
                ),
                StatusChip(balanced ? 'الميزان متوازن' : 'الميزان غير متوازن!', balanced ? Colors.green : Colors.red),
                Text('مجموع المدين ${formatNumber(asNum(d['total_debit']))} | مجموع الدائن ${formatNumber(asNum(d['total_credit']))}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ]),
              const SizedBox(height: 8),
              Card(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    showCheckboxColumn: false,
                    columns: const [
                      DataColumn(label: Text('الحساب')),
                      DataColumn(label: Text('مدين'), numeric: true),
                      DataColumn(label: Text('دائن'), numeric: true),
                      DataColumn(label: Text('الرصيد'), numeric: true),
                    ],
                    rows: tableRows,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('القيود تُرحَّل تلقائياً من الوصولات والمطابقات والإيداعات والرواتب والتوريدات؛ اضغط على حساب لعرض حركاته.',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Ledger extends StatefulWidget {
  final String? initialAccount;
  const _Ledger({super.key, this.initialAccount});

  @override
  State<_Ledger> createState() => _LedgerState();
}

class _LedgerState extends State<_Ledger> {
  String? _account;
  late DateTime _start;
  DateTime _end = DateTime.now();
  List<Map> _accounts = [];

  @override
  void initState() {
    super.initState();
    _account = widget.initialAccount ?? '1100';
    final n = DateTime.now();
    _start = DateTime(n.year, n.month, 1);
    ApiClient.instance.get('/finance/accounts').then((a) {
      if (mounted) setState(() => _accounts = (a as List).cast<Map>());
    }).catchError((_) {});
  }

  Future<void> _pick(bool start) async {
    final p = await showDatePicker(context: context, initialDate: start ? _start : _end, firstDate: DateTime(2025), lastDate: DateTime.now());
    if (p != null) setState(() => start ? _start = p : _end = p);
  }

  @override
  Widget build(BuildContext context) {
    final q = 'start=${apiDate(_start)}&end=${apiDate(_end)}${_account != null ? '&account=$_account' : ''}';
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          DropdownButton<String?>(
            value: _account,
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('كل الحسابات')),
              ..._accounts.map((a) => DropdownMenuItem<String?>(value: '${a['code']}', child: Text('${a['code']} ${a['name']}'))),
              if (_account != null && !_accounts.any((a) => a['code'] == _account))
                DropdownMenuItem<String?>(value: _account, child: Text(_account!)),
            ],
            onChanged: (v) => setState(() => _account = v),
          ),
          OutlinedButton(onPressed: () => _pick(true), child: Text('من ${apiDate(_start)}')),
          OutlinedButton(onPressed: () => _pick(false), child: Text('إلى ${apiDate(_end)}')),
        ]),
      ),
      Expanded(
        child: ApiView(
          path: '/finance/ledger?$q',
          builder: (context, d, reload) {
            final rows = (d['postings'] as List).cast<Map>();
            final hasBal = d['account'] != null;
            return ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                if (hasBal)
                  Wrap(spacing: 8, children: [
                    Chip(label: Text('الرصيد الافتتاحي ${formatIqd(asNum(d['opening']))}')),
                    Chip(label: Text('الرصيد الختامي ${formatIqd(asNum(d['closing']))}')),
                  ]),
                if (d['truncated'] == true) const Text('عُرضت أول 500 حركة فقط؛ ضيّق الفترة.', style: TextStyle(color: Colors.orange)),
                if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('لا حركات في هذه الفترة'))),
                if (rows.isNotEmpty)
                  Card(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columnSpacing: 18,
                        columns: [
                          const DataColumn(label: Text('التاريخ')),
                          if (!hasBal) const DataColumn(label: Text('الحساب')),
                          const DataColumn(label: Text('المصدر')),
                          const DataColumn(label: Text('البيان')),
                          const DataColumn(label: Text('مدين'), numeric: true),
                          const DataColumn(label: Text('دائن'), numeric: true),
                          if (hasBal) const DataColumn(label: Text('الرصيد'), numeric: true),
                        ],
                        rows: rows
                            .map((r) => DataRow(cells: [
                                  DataCell(Text('${formatDate(r['posted_at'])} ${formatTime(r['posted_at'])}')),
                                  if (!hasBal) DataCell(Text('${r['account']} ${r['account_name']}')),
                                  DataCell(Text('${_sourceLabels[r['source']] ?? r['source']} ${r['ref']}')),
                                  DataCell(Text('${r['memo'] ?? ''}${r['employee_code'] != null ? ' (${r['employee_code']})' : ''}')),
                                  DataCell(Text((asNum(r['debit']) ?? 0) == 0 ? '' : formatNumber(asNum(r['debit'])))),
                                  DataCell(Text((asNum(r['credit']) ?? 0) == 0 ? '' : formatNumber(asNum(r['credit'])))),
                                  if (hasBal) DataCell(Text(formatNumber(asNum(r['balance'])), style: const TextStyle(fontWeight: FontWeight.bold))),
                                ]))
                            .toList(),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ]);
  }
}

class _IncomeStatement extends StatefulWidget {
  const _IncomeStatement();

  @override
  State<_IncomeStatement> createState() => _IncomeStatementState();
}

class _IncomeStatementState extends State<_IncomeStatement> {
  String _period = currentPeriod();

  Widget _line(String label, dynamic amount, {bool bold = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.bold : null))),
          Text(formatIqd(asNum(amount)), style: TextStyle(fontWeight: bold ? FontWeight.bold : null, color: color)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/finance/income-statement?period=$_period',
      builder: (context, d, reload) {
        final rev = (d['revenue'] as List).cast<Map>();
        final exp = (d['expenses'] as List).cast<Map>();
        final net = (asNum(d['net_income']) ?? 0).toDouble();
        final pt = d['pass_through'] as Map;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: DropdownButton<String>(
                value: _period,
                items: {...recentPeriods(), _period}.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                onChanged: (v) => setState(() => _period = v ?? _period),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('قائمة الدخل - $_period', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const Divider(),
                    const Text('الإيرادات', style: TextStyle(color: Colors.teal, fontWeight: FontWeight.bold)),
                    if (rev.isEmpty) const Text('لا إيرادات', style: TextStyle(color: Colors.grey)),
                    ...rev.map((r) => _line('${r['name']}', r['amount'])),
                    _line('مجموع الإيرادات', d['total_revenue'], bold: true),
                    const Divider(),
                    const Text('المصروفات', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                    if (exp.isEmpty) const Text('لا مصروفات', style: TextStyle(color: Colors.grey)),
                    ...exp.map((r) => _line('${r['name']}', r['amount'])),
                    _line('مجموع المصروفات', d['total_expenses'], bold: true),
                    const Divider(thickness: 2),
                    _line(net >= 0 ? 'صافي الربح' : 'صافي الخسارة', net, bold: true, color: net >= 0 ? Colors.green : Colors.red),
                  ]),
                ),
              ),
            ),
            Card(
              color: Colors.blueGrey.withValues(alpha: 0.06),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('أموال دائرة الماء (خارج الإيرادات)', style: TextStyle(fontWeight: FontWeight.bold)),
                  _line('حُصّلت نيابةً عنها هذا الشهر', pt['government_collected']),
                  _line('وُرّدت لها هذا الشهر', pt['government_remitted']),
                  Text('${pt['note']}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Journal extends StatefulWidget {
  const _Journal();

  @override
  State<_Journal> createState() => _JournalState();
}

class _JournalState extends State<_Journal> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _new() async {
    List<Map> accounts;
    try {
      accounts = ((await ApiClient.instance.get('/finance/accounts')) as List).cast<Map>().where((a) => a['manual'] == true).toList();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => _JournalDialog(accounts: accounts));
    if (ok == null || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/finance/journal', ok), success: 'تم ترحيل القيد');
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/finance/journal',
      builder: (context, data, reload) {
        final list = (data as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (_canWrite)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ElevatedButton.icon(onPressed: _new, icon: const Icon(Icons.add), label: const Text('قيد يدوي جديد')),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('للتسويات فقط: عمولات المصرف، الأرصدة الافتتاحية، تسوية الحساب المعلق، تسديد الضرائب. '
                  'القيد لا يُحذف؛ يُعكس بقيد معاكس.', style: TextStyle(color: Colors.grey, fontSize: 12)),
            ),
            if (list.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('لا قيود يدوية'))),
            ...list.map((e) {
              final lines = (e['lines'] as List).cast<Map>();
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text('#${e['id']} | ${formatDate(e['posted_at'])} | ${e['memo']}',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      Text('${e['created_by']}', style: const TextStyle(color: Colors.grey)),
                      if (_canWrite && !'${e['memo']}'.startsWith('عكس القيد'))
                        TextButton(
                          onPressed: () async {
                            final ok = await confirm(context, 'عكس القيد #${e['id']}', 'سيُرحَّل قيد معاكس بتاريخ اليوم.');
                            if (!ok || !context.mounted) return;
                            await runApi(context, () => ApiClient.instance.post('/finance/journal/${e['id']}/reverse'));
                            if (context.mounted) reload();
                          },
                          child: const Text('عكس'),
                        ),
                    ]),
                    ...lines.map((l) => Row(children: [
                          Expanded(child: Text('${l['account']} ${l['account_name']}')),
                          SizedBox(width: 110, child: Text((asNum(l['debit']) ?? 0) > 0 ? 'مدين ${formatNumber(asNum(l['debit']))}' : '')),
                          SizedBox(width: 110, child: Text((asNum(l['credit']) ?? 0) > 0 ? 'دائن ${formatNumber(asNum(l['credit']))}' : '')),
                        ])),
                  ]),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

class _JournalDialog extends StatefulWidget {
  final List<Map> accounts;
  const _JournalDialog({required this.accounts});

  @override
  State<_JournalDialog> createState() => _JournalDialogState();
}

class _JournalLine {
  String? account;
  final debit = TextEditingController();
  final credit = TextEditingController();
  void dispose() {
    debit.dispose();
    credit.dispose();
  }
}

class _JournalDialogState extends State<_JournalDialog> {
  final _memo = TextEditingController();
  final List<_JournalLine> _lines = [_JournalLine(), _JournalLine()];
  DateTime _date = DateTime.now();
  String? _error;

  @override
  void dispose() {
    _memo.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  double _v(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '').trim()) ?? 0;

  void _submit() {
    final lines = <Map<String, dynamic>>[];
    for (final l in _lines) {
      final d = _v(l.debit), c = _v(l.credit);
      if (l.account == null && d == 0 && c == 0) continue;
      if (l.account == null) return setState(() => _error = 'اختر الحساب لكل سطر');
      if ((d > 0) == (c > 0)) return setState(() => _error = 'كل سطر مدين أو دائن فقط');
      lines.add({'account': l.account, 'debit': d, 'credit': c});
    }
    final td = lines.fold<double>(0, (s, l) => s + (l['debit'] as double));
    final tc = lines.fold<double>(0, (s, l) => s + (l['credit'] as double));
    if (lines.length < 2) return setState(() => _error = 'القيد يحتاج سطرين على الأقل');
    if ((td - tc).abs() >= 0.01) return setState(() => _error = 'غير متوازن: المدين ${formatNumber(td)} والدائن ${formatNumber(tc)}');
    if (_memo.text.trim().length < 3) return setState(() => _error = 'اكتب بيان القيد');
    Navigator.pop(context, {'entry_date': apiDate(_date), 'memo': _memo.text.trim(), 'lines': lines});
  }

  @override
  Widget build(BuildContext context) {
    final td = _lines.fold<double>(0, (s, l) => s + _v(l.debit));
    final tc = _lines.fold<double>(0, (s, l) => s + _v(l.credit));
    return AlertDialog(
      title: const Text('قيد يدوي'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: _memo, decoration: const InputDecoration(labelText: 'البيان'))),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () async {
                  final p = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2025), lastDate: DateTime.now());
                  if (p != null) setState(() => _date = p);
                },
                child: Text(apiDate(_date)),
              ),
            ]),
            const SizedBox(height: 8),
            ..._lines.map((l) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        initialValue: l.account,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'الحساب', isDense: true),
                        items: widget.accounts
                            .map((a) => DropdownMenuItem(value: '${a['code']}', child: Text('${a['code']} ${a['name']}', overflow: TextOverflow.ellipsis)))
                            .toList(),
                        onChanged: (v) => setState(() => l.account = v),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(controller: l.debit, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(labelText: 'مدين', isDense: true)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(controller: l.credit, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(labelText: 'دائن', isDense: true)),
                    ),
                  ]),
                )),
            Row(children: [
              TextButton.icon(
                onPressed: _lines.length >= 10 ? null : () => setState(() => _lines.add(_JournalLine())),
                icon: const Icon(Icons.add),
                label: const Text('سطر'),
              ),
              const Spacer(),
              Text('مدين ${formatNumber(td)} | دائن ${formatNumber(tc)}',
                  style: TextStyle(color: (td - tc).abs() < 0.01 && td > 0 ? Colors.green : Colors.red)),
            ]),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        ElevatedButton(onPressed: _submit, child: const Text('ترحيل')),
      ],
    );
  }
}

// ================================================================ government remittances

class RemittancesTab extends StatefulWidget {
  const RemittancesTab({super.key});

  @override
  State<RemittancesTab> createState() => _RemittancesTabState();
}

class _RemittancesTabState extends State<RemittancesTab> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _new(double due) async {
    final amount = TextEditingController(text: due > 0 ? due.floor().toString() : '');
    final ref = TextEditingController();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تسجيل توريد لدائرة الماء'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('المستحق حالياً: ${formatIqd(due)}'),
            TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ')),
            TextField(controller: ref, decoration: const InputDecoration(labelText: 'رقم الحوالة / الصك')),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تسجيل')),
        ],
      ),
    );
    final body = {
      'amount': double.tryParse(amount.text.replaceAll(',', '').trim()) ?? 0,
      'bank_ref': ref.text.trim(),
      'note': note.text.trim().isEmpty ? null : note.text.trim(),
    };
    Future.delayed(const Duration(milliseconds: 400), () {
      amount.dispose();
      ref.dispose();
      note.dispose();
    });
    if (ok != true || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/finance/remittances', body), success: 'تم تسجيل التوريد');
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/finance/remittances',
      builder: (context, d, reload) {
        final items = (d['items'] as List).cast<Map>();
        final due = (asNum(d['due']) ?? 0).toDouble();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(label: 'مستحق لدائرة الماء', value: formatIqd(due), icon: Icons.account_balance, color: due > 0 ? Colors.deepOrange : Colors.green),
                KpiCard(label: 'رصيد المصرف المؤكد', value: formatIqd(asNum(d['bank'])), icon: Icons.savings, color: Colors.green),
                KpiCard(label: 'الحصة الحكومية المحصلة (الكلي)', value: formatIqd(asNum(d['government_collected_total'])), icon: Icons.summarize, color: Colors.blueGrey),
                KpiCard(label: 'المورَّد (الكلي)', value: formatIqd(asNum(d['remitted_total'])), icon: Icons.outbox, color: Colors.indigo),
              ]),
              if (_canWrite)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: ElevatedButton.icon(onPressed: due > 0 ? () => _new(due) : null, icon: const Icon(Icons.send), label: const Text('تسجيل توريد')),
                  ),
                ),
              const Text('لا يمكن توريد أكثر من المستحق، ولا أكثر من رصيد المصرف المؤكد (الإيداعات المدققة).',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SectionTitle('سجل التوريدات'),
              if (items.isEmpty) const Text('لا توريدات بعد', style: TextStyle(color: Colors.grey)),
              ...items.map((r) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.outbox, color: Colors.indigo),
                      title: Text('${formatIqd(asNum(r['amount']))} | ${r['bank_ref']}'),
                      subtitle: Text('${formatDate(r['remitted_at'])} | ${r['created_by']}${r['note'] != null ? ' | ${r['note']}' : ''}'),
                    ),
                  )),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ arrears aging

class AgingTab extends StatelessWidget {
  const AgingTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/finance/aging',
      builder: (context, d, reload) {
        final buckets = (d['buckets'] as List).cast<Map>();
        final sectors = (d['sectors'] as List).cast<Map>();
        final top = (d['top'] as List).cast<Map>();
        const colors = [Colors.green, Colors.amber, Colors.orange, Colors.deepOrange, Colors.red];
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              KpiCard(
                width: 320,
                label: 'متأخرات تقديرية (الحصة الحكومية)',
                value: formatIqd(asNum(d['total_estimated'])),
                icon: Icons.hourglass_bottom,
                color: Colors.deepOrange,
              ),
              const SectionTitle('أعمار المتأخرات (أيام منذ آخر دفعة)'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    SimpleBarChart(
                      labels: buckets.map((b) => '${b['key']}').toList(),
                      values: buckets.map((b) => (asNum(b['estimated']) ?? 0).toDouble()).toList(),
                      colors: colors,
                      height: 200,
                    ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (var i = 0; i < buckets.length; i++)
                        StatusChip('${buckets[i]['label']} (${buckets[i]['key']}): ${buckets[i]['properties']} عقار', colors[i]),
                    ]),
                  ]),
                ),
              ),
              const SectionTitle('حسب القاطع'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: HBarList(
                    color: Colors.deepOrange,
                    rows: sectors
                        .map((s) => (
                              label: '${s['name']}',
                              value: (asNum(s['estimated']) ?? 0).toDouble(),
                              trailing: '${compactIqd((asNum(s['estimated']) ?? 0).toDouble())} | ${s['overdue']}/${s['properties']} متأخر',
                            ))
                        .toList(),
                  ),
                ),
              ),
              const SectionTitle('أعلى العقارات متأخرات'),
              ...top.map((p) => Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: (asNum(p['days']) ?? 0) > 90 ? Colors.red.shade100 : Colors.orange.shade100,
                        child: Text('${p['days']}', style: const TextStyle(fontSize: 12)),
                      ),
                      title: Text('${p['property_code']} - ${p['citizen']}'),
                      subtitle: Text('${p['sector']} | ${p['address']} | ${p['never_paid'] == true ? 'لم يدفع منذ التسجيل' : 'آخر دفعة ${formatDate(p['last_paid'])}'}'),
                      trailing: Text(formatIqd(asNum(p['estimated'])), style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  )),
              Padding(padding: const EdgeInsets.all(8), child: Text('${d['note']}', style: const TextStyle(color: Colors.grey, fontSize: 12))),
            ],
          ),
        );
      },
    );
  }
}

// ================================================================ escalated cash differences

class DifferencesTab extends StatefulWidget {
  const DifferencesTab({super.key});

  @override
  State<DifferencesTab> createState() => _DifferencesTabState();
}

class _DifferencesTabState extends State<DifferencesTab> {
  final _view = GlobalKey<ApiViewState>();

  Future<void> _close(Map r, String action) async {
    final note = await askNote(context, action == 'salary_deduction' ? 'استقطاع العجز من راتب الجابي' : 'شطب الفرق', required: true);
    if (note == null || !mounted) return;
    await runApi(context, () => ApiClient.instance.post('/finance/reconciliations/${r['id']}/close', {'action': action, 'note': note}),
        success: 'تمت التسوية');
    _view.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return ApiView(
      key: _view,
      path: '/finance/escalations',
      builder: (context, data, reload) {
        final list = (data as List).cast<Map>();
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              const Text('فروقات نقدية أحالها المشرفون. تبقى في الحساب المعلق حتى تقرر المالية: استقطاعها من الراتب القادم أو شطبها.',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 8),
              if (list.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('لا فروقات محالة'))),
              ...list.map((r) {
                final diff = (asNum(r['difference']) ?? 0).toDouble();
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text('${r['collector_code']} - ${r['collector_name']} | المشرف ${r['supervisor_code']}',
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        StatusChip(diff < 0 ? 'عجز ${formatIqd(-diff)}' : 'زيادة ${formatIqd(diff)}', diff < 0 ? Colors.red : Colors.orange),
                      ]),
                      Text('المتوقع ${formatIqd(asNum(r['expected_cash']))} | المعدود ${formatIqd(asNum(r['counted_cash']))} | ${formatDate(r['created_at'])}'),
                      if (r['resolution_note'] != null) Text('ملاحظة المشرف: ${r['resolution_note']}', style: const TextStyle(color: Colors.grey)),
                      if (_canWrite)
                        Wrap(spacing: 8, children: [
                          if (diff < 0)
                            ElevatedButton(onPressed: () => _close(r, 'salary_deduction'), child: const Text('استقطاع من الراتب')),
                          OutlinedButton(onPressed: () => _close(r, 'write_off'), child: Text(diff < 0 ? 'شطب كخسارة' : 'تسجيل كإيراد')),
                        ]),
                    ]),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }
}
