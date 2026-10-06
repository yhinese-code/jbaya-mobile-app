import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../shared/ui.dart';
import 'charts.dart';

Color riskColor(String? level) => level == 'high' ? Colors.red : (level == 'medium' ? Colors.orange : Colors.green);
Color severityColor(String? s) => s == 'high' ? Colors.red : (s == 'medium' ? Colors.orange : Colors.blueGrey);
const severityLabels = {'high': 'مرتفع', 'medium': 'متوسط', 'low': 'منخفض'};

Widget _daysPicker(int days, ValueChanged<int> onChanged) => SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 7, label: Text('7 أيام')),
        ButtonSegment(value: 30, label: Text('30 يوم')),
        ButtonSegment(value: 90, label: Text('90 يوم')),
      ],
      selected: {days},
      onSelectionChanged: (s) => onChanged(s.first),
    );

// ================================================================ risk scores

class RiskTab extends StatefulWidget {
  const RiskTab({super.key});

  @override
  State<RiskTab> createState() => _RiskTabState();
}

class _RiskTabState extends State<RiskTab> {
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          _daysPicker(_days, (v) => setState(() => _days = v)),
          const SizedBox(width: 12),
          const Expanded(
            child: Text('درجة من 0 إلى 100 تجمع مؤشرات الاحتيال لكل جابٍ؛ افتح البطاقة لرؤية سبب كل نقطة.',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ]),
      ),
      Expanded(
        child: ApiView(
          path: '/finance/risk?days=$_days',
          builder: (context, data, reload) {
            final list = (data['collectors'] as List).cast<Map>();
            if (list.isEmpty) return const Center(child: Text('لا يوجد جباة فعالون'));
            final high = list.where((c) => c['level'] == 'high').length;
            final medium = list.where((c) => c['level'] == 'medium').length;
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  Wrap(spacing: 8, children: [
                    StatusChip('مرتفع: $high', Colors.red),
                    StatusChip('متوسط: $medium', Colors.orange),
                    StatusChip('منخفض: ${list.length - high - medium}', Colors.green),
                  ]),
                  const SizedBox(height: 8),
                  ...list.map((c) => _RiskCard(c: c, days: _days)),
                ],
              ),
            );
          },
        ),
      ),
    ]);
  }
}

class _RiskCard extends StatelessWidget {
  final Map c;
  final int days;
  const _RiskCard({required this.c, required this.days});

  @override
  Widget build(BuildContext context) {
    final color = riskColor(c['level'] as String?);
    final factors = (c['factors'] as List).cast<Map>();
    final reasons = (c['top_reasons'] as List).cast<String>();
    return Card(
      child: ExpansionTile(
        leading: SizedBox(
          width: 46,
          height: 46,
          child: Stack(alignment: Alignment.center, children: [
            CircularProgressIndicator(
              value: (asNum(c['score']) ?? 0) / 100,
              strokeWidth: 5,
              color: color,
              backgroundColor: color.withValues(alpha: 0.12),
            ),
            Text('${c['score']}', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
        title: Text('${c['employee_code']} - ${c['full_name']}'),
        subtitle: Text('${formatIqd(asNum(c['collected']))} | ${c['receipts']} وصل'
            '${reasons.isNotEmpty ? '\nأبرز الأسباب: ${reasons.join('، ')}' : ''}'),
        trailing: StatusChip('${c['level_label']}', color),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          ...factors.map((f) {
            final pts = (asNum(f['points']) ?? 0).toDouble();
            final w = (asNum(f['weight']) ?? 1).toDouble();
            final fc = pts >= w * 0.6 ? Colors.red : (pts >= w * 0.3 ? Colors.orange : Colors.green);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(flex: 3, child: Text('${f['label']}', style: const TextStyle(fontSize: 13))),
                  Expanded(
                    flex: 2,
                    child: LinearProgressIndicator(value: w > 0 ? pts / w : 0, minHeight: 8, color: fc, backgroundColor: fc.withValues(alpha: 0.1)),
                  ),
                  SizedBox(width: 56, child: Text(' ${pts.toStringAsFixed(1)}/${w.toStringAsFixed(0)}', style: const TextStyle(fontSize: 12))),
                ]),
                Text('${f['display']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ]),
            );
          }),
          if (c['low_ticket'] != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text('متوسط الفاتورة منخفض: ${c['low_ticket']}', style: const TextStyle(color: Colors.orange)),
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              icon: const Icon(Icons.analytics),
              label: const Text('تحليل بنفورد والأرقام لهذا الجابي'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text('تحليل الأرقام - ${c['employee_code']}')),
                  body: BenfordTab(collector: '${c['employee_code']}'),
                ),
              )),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================ anomalies

class AnomaliesTab extends StatefulWidget {
  const AnomaliesTab({super.key});

  @override
  State<AnomaliesTab> createState() => _AnomaliesTabState();
}

class _AnomaliesTabState extends State<AnomaliesTab> {
  int _days = 30;
  String? _severity;
  String? _type;

  static const _typeLabels = {
    'bill_flag': 'فواتير عليها ملاحظات',
    'repeated_zero': 'عداد لا يتحرك',
    'off_hours': 'خارج ساعات العمل',
    'rapid_receipts': 'وصولات متقاربة جداً',
    'far_from_property': 'بعيد عن العقار',
    'cash_held': 'احتفاظ بالنقد',
    'handover_delay': 'تأخر التسليم للمقر',
    'handover_difference': 'فرق عند العدّ في المقر',
    'master_share': 'الرمز الرئيسي',
    'estimate_share': 'تقديرات مرتفعة',
    'digit_preference': 'تفضيل الأرقام',
    'low_ticket': 'فواتير منخفضة',
    'shortage': 'عجز نقدي',
  };

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: _daysPicker(_days, (v) => setState(() => _days = v))),
      Expanded(
        child: ApiView(
          path: '/finance/anomalies?days=$_days',
          builder: (context, data, reload) {
            final all = (data['items'] as List).cast<Map>();
            final types = all.map((a) => a['type'] as String).toSet().toList()..sort();
            final items = all.where((a) => (_severity == null || a['severity'] == _severity) && (_type == null || a['type'] == _type)).toList();
            final counts = (data['counts'] as Map?) ?? {};
            return RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    for (final s in const ['high', 'medium', 'low'])
                      FilterChip(
                        selected: _severity == s,
                        label: Text('${severityLabels[s]} (${counts[s] ?? 0})'),
                        selectedColor: severityColor(s).withValues(alpha: 0.2),
                        onSelected: (v) => setState(() => _severity = v ? s : null),
                      ),
                    DropdownButton<String?>(
                      value: types.contains(_type) ? _type : null,
                      hint: const Text('كل الأنواع'),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('كل الأنواع')),
                        ...types.map((t) => DropdownMenuItem<String?>(value: t, child: Text(_typeLabels[t] ?? t))),
                      ],
                      onChanged: (v) => setState(() => _type = v),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  if (items.isEmpty)
                    const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('لا توجد حالات شاذة ضمن هذا التصفية'))),
                  ...items.map((a) {
                    final color = severityColor(a['severity'] as String?);
                    return Card(
                      child: ListTile(
                        leading: Icon(a['severity'] == 'high' ? Icons.error : Icons.warning_amber, color: color),
                        title: Text('${a['title']}${a['collector'] != null ? ' | ${a['collector']}' : ''}'),
                        subtitle: Text('${a['detail']}${a['at'] != null ? '\n${formatDate(a['at'])} ${formatTime(a['at'])}' : ''}'),
                        isThreeLine: a['at'] != null,
                        trailing: StatusChip(_typeLabels[a['type']] ?? '${a['type']}', color),
                      ),
                    );
                  }),
                ],
              ),
            );
          },
        ),
      ),
    ]);
  }
}

// ================================================================ Benford

class BenfordTab extends StatefulWidget {
  final String? collector;
  const BenfordTab({super.key, this.collector});

  @override
  State<BenfordTab> createState() => _BenfordTabState();
}

class _BenfordTabState extends State<BenfordTab> {
  String _dataset = 'consumption';
  String? _collector;
  int _days = 365;

  @override
  void initState() {
    super.initState();
    _collector = widget.collector;
    ApiClient.instance.get('/finance/overview?days=7').then((o) {
      if (!mounted) return;
      setState(() => _known = ((o['collectors'] as List).cast<Map>()).map((c) => '${c['employee_code']}').toList()..sort());
    }).catchError((_) {});
  }

  Color _levelColor(String? l) => switch (l) {
        'close' => Colors.green,
        'acceptable' => Colors.teal,
        'marginal' => Colors.orange,
        'nonconformity' => Colors.red,
        _ => Colors.grey,
      };

  Widget _testCard(String title, Map t, {String refName = 'قانون بنفورد'}) {
    final obs = (t['observed'] as List).map((v) => (asNum(v) ?? 0).toDouble()).toList();
    final exp = (t['expected'] as List).map((v) => (asNum(v) ?? 0).toDouble()).toList();
    final suspicious = (t['suspicious_digits'] as List? ?? []).cast<int>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            StatusChip('${t['label']}', _levelColor(t['level'] as String?)),
            Text('n = ${t['n']} | MAD = ${t['mad'] ?? '-'} | χ² = ${t['chi2'] ?? '-'} | p = ${t['p_value'] ?? '-'}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
          const SizedBox(height: 8),
          SimpleBarChart(
            labels: List.generate(9, (i) => '${i + 1}'),
            values: obs.map((v) => v * 100).toList(),
            reference: exp.map((v) => v * 100).toList(),
            colors: List.generate(9, (i) => suspicious.contains(i + 1) ? Colors.red.shade300 : Colors.indigo),
            yFormat: (v) => '${v.toStringAsFixed(0)}%',
            valueName: 'الفعلي (أول رقم)',
            referenceName: refName,
          ),
          if (suspicious.isNotEmpty)
            Text('أرقام منحرفة إحصائياً: ${suspicious.join('، ')}', style: const TextStyle(color: Colors.red, fontSize: 12)),
        ]),
      ),
    );
  }

  List<String> _known = [];

  Widget _filters() {
    final collectors = [..._known];
    if (_collector != null && !collectors.contains(_collector)) collectors.insert(0, _collector!);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'consumption', label: Text('الاستهلاك')),
            ButtonSegment(value: 'gov_amount', label: Text('مبالغ الوصولات')),
          ],
          selected: {_dataset},
          onSelectionChanged: (s) => setState(() => _dataset = s.first),
        ),
        DropdownButton<String?>(
          value: _collector,
          hint: const Text('كل الجباة'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('كل الجباة')),
            ...collectors.map((c) => DropdownMenuItem<String?>(value: c, child: Text(c))),
          ],
          onChanged: (v) => setState(() => _collector = v),
        ),
        DropdownButton<int>(
          value: _days,
          items: const [
            DropdownMenuItem(value: 90, child: Text('آخر 90 يوماً')),
            DropdownMenuItem(value: 365, child: Text('آخر سنة')),
            DropdownMenuItem(value: 1095, child: Text('آخر 3 سنوات')),
          ],
          onChanged: (v) => setState(() => _days = v ?? 365),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = 'dataset=$_dataset&days=$_days${_collector != null ? '&collector=${Uri.encodeQueryComponent(_collector!)}' : ''}';
    return Column(children: [
      _filters(),
      Expanded(child: _results(q)),
    ]);
  }

  Widget _results(String q) {
    return ApiView(
      path: '/finance/benford?$q',
      builder: (context, d, reload) {
        final table = (d['collectors'] as List).cast<Map>();
        final ld = d['last_digit'] as Map;
        final ldCounts = (ld['counts'] as List).map((v) => (asNum(v) ?? 0).toDouble()).toList();
        final ldN = (asNum(ld['n']) ?? 0).toDouble();
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _testCard('${d['dataset_label']}${_collector != null ? ' - $_collector' : ' - الشركة كلها'} مقابل قانون بنفورد', d['law'] as Map),
            if (d['vs_peers'] != null) _testCard('مقارنة مع بقية الجباة', d['vs_peers'] as Map, refName: 'توزيع بقية الجباة'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    const Text('اختبار الرقم الأخير لقراءات العدادات', style: TextStyle(fontWeight: FontWeight.bold)),
                    if (ld['suspicious'] == true) const StatusChip('تفضيل أرقام مشبوه', Colors.red),
                    Text('n = ${ld['n']} | تنتهي بـ 0 أو 5: ${pctText(ld['share_0_5'])} (الطبيعي 20%) | p = ${ld['p_value'] ?? '-'}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ]),
                  const SizedBox(height: 8),
                  SimpleBarChart(
                    labels: List.generate(10, (i) => '$i'),
                    values: ldCounts.map((c) => ldN > 0 ? c / ldN * 100 : 0.0).toList(),
                    reference: List.filled(10, 10.0),
                    colors: List.generate(10, (i) => i == 0 || i == 5 ? Colors.orange : Colors.teal),
                    yFormat: (v) => '${v.toStringAsFixed(0)}%',
                    height: 180,
                    valueName: 'الفعلي (آخر رقم)',
                    referenceName: 'المتوقع 10%',
                  ),
                ]),
              ),
            ),
            const SectionTitle('حسب الجابي'),
            Card(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  showCheckboxColumn: false,
                  columns: const [
                    DataColumn(label: Text('الجابي')),
                    DataColumn(label: Text('عدد القيم'), numeric: true),
                    DataColumn(label: Text('مقابل الزملاء')),
                    DataColumn(label: Text('مقابل القانون')),
                    DataColumn(label: Text('قراءات'), numeric: true),
                    DataColumn(label: Text('تنتهي بـ 0/5'), numeric: true),
                  ],
                  rows: table
                      .map((r) => DataRow(
                            onSelectChanged: (_) => setState(() => _collector = '${r['collector']}'),
                            cells: [
                              DataCell(Text('${r['collector']}')),
                              DataCell(Text('${r['n']}')),
                              DataCell(StatusChip('${r['peer_label']}${r['peer_mad'] != null ? ' (${r['peer_mad']})' : ''}',
                                  _levelColor(r['peer_level'] as String?))),
                              DataCell(StatusChip('${r['label']}${r['mad'] != null ? ' (${r['mad']})' : ''}',
                                  _levelColor(r['level'] as String?))),
                              DataCell(Text('${r['readings_n']}')),
                              DataCell(Text(pctText(r['share_0_5']),
                                  style: TextStyle(color: r['digit_preference'] == true ? Colors.red : null))),
                            ],
                          ))
                      .toList(),
                ),
              ),
            ),
            ...(d['notes'] as List).map((n) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('• $n', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                )),
          ],
        );
      },
    );
  }
}

// ================================================================ for Command (dark): risk + anomalies

class FinancialRiskCommandTab extends StatelessWidget {
  const FinancialRiskCommandTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(children: [
        TabBar(tabs: [Tab(text: 'درجات المخاطر'), Tab(text: 'الحالات الشاذة')]),
        Expanded(child: TabBarView(children: [RiskTab(), AnomaliesTab()])),
      ]),
    );
  }
}


/// Finance / owner: the three fraud views under one tab.
class FraudTab extends StatelessWidget {
  const FraudTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 3,
      child: Column(children: [
        TabBar(tabs: [Tab(text: 'درجات المخاطر'), Tab(text: 'الحالات الشاذة'), Tab(text: 'تحليل الأرقام')]),
        Expanded(child: TabBarView(children: [RiskTab(), AnomaliesTab(), BenfordTab()])),
      ]),
    );
  }
}
