import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../command/cc_widgets.dart';
import '../command/health_tab.dart';
import '../finance/charts.dart' show KpiCard;
import '../shared/ui.dart';
import 'tech_access_tabs.dart';
import 'tech_accounts_tab.dart';
import 'tech_common.dart';
import 'tech_sectors_tab.dart';
import 'tech_settings_tabs.dart';
import 'tech_watch_tabs.dart';

/// The tech panel ("god mode"): devices, sessions, accounts, every setting and formula, switches,
/// the tab-permission matrix, sectors and tariffs, WhatsApp, fraud watch, the audit log and system health.
class TechPortalScreen extends StatelessWidget {
  const TechPortalScreen({super.key});

  static const _tabs = [
    Tab(icon: Icon(Icons.dashboard), text: 'نظرة عامة'),
    Tab(icon: Icon(Icons.phonelink_lock), text: 'الأجهزة'),
    Tab(icon: Icon(Icons.vpn_key), text: 'الجلسات'),
    Tab(icon: Icon(Icons.manage_accounts), text: 'الحسابات'),
    Tab(icon: Icon(Icons.tune), text: 'الإعدادات والمعادلات'),
    Tab(icon: Icon(Icons.admin_panel_settings), text: 'الصلاحيات'),
    Tab(icon: Icon(Icons.map), text: 'القواطع والتعرفة'),
    Tab(icon: Icon(Icons.chat), text: 'واتساب'),
    Tab(icon: Icon(Icons.gpp_maybe), text: 'مكافحة التلاعب'),
    Tab(icon: Icon(Icons.history), text: 'سجل التدقيق'),
    Tab(icon: Icon(Icons.monitor_heart), text: 'صحة النظام'),
  ];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text('لوحة التقنية - ${Session.instance.fullName}', style: const TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: kTechColor,
          foregroundColor: Colors.white,
          actions: const [LogoutButton()],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.cyanAccent,
            tabs: _tabs,
          ),
        ),
        body: TabBarView(children: [
          const TechOverviewTab(),
          const TechDevicesTab(),
          const TechSessionsTab(),
          const TechAccountsTab(),
          const TechSettingsTab(),
          const TechPermissionsTab(),
          const TechSectorsTab(),
          const TechWhatsAppTab(),
          const TechFraudTab(),
          const TechAuditTab(),
          // HealthTab is drawn for the dark Command theme (light text on dark panels).
          Theme(data: CC.theme(context), child: const ColoredBox(color: CC.bg, child: HealthTab())),
        ]),
      ),
    );
  }
}

// ================================================================ overview

class TechOverviewTab extends StatelessWidget {
  const TechOverviewTab({super.key});

  static const _gainModes = {
    'not_set': 'لم تُحدد بعد',
    'baseline_2025': 'فوق إيرادات 2025 لنفس الشهر',
    'per_house': 'زيادة كل منزل عن فاتورته السابقة',
  };

  @override
  Widget build(BuildContext context) {
    return ApiView(
      path: '/tech/overview',
      builder: (context, data, reload) {
        final d = data as Map;
        final pending = toInt(d['pending_devices']);
        final sharing = toInt(d['device_sharing_attempts_7d']);
        final roles = ((d['roles'] as List?) ?? const []).cast<Map>();
        final switches = (d['switches'] as Map?) ?? const {};
        final maintenance = d['maintenance_mode'] == true;
        final waLive = d['whatsapp_mode'] == 'live';
        final gain = txt(d['gain_share_mode'], '');
        return RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (maintenance)
                Card(
                  color: Colors.red.withValues(alpha: 0.1),
                  child: const ListTile(
                    leading: Icon(Icons.construction, color: Colors.red, size: 32),
                    title: Text('وضع الصيانة مفعّل', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
                    subtitle: Text('النظام للقراءة فقط، ولا يُحفظ أي تغيير إلا من لوحة التقنية'),
                  ),
                ),
              if (pending > 0)
                Card(
                  color: Colors.orange.withValues(alpha: 0.14),
                  child: ListTile(
                    leading: const Icon(Icons.phonelink_lock, color: Colors.deepOrange, size: 32),
                    title: Text('$pending جهاز بانتظار الموافقة', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    subtitle: const Text('الموظف لا يستطيع الدخول من الجهاز الجديد حتى توافق عليه'),
                    trailing: TextButton(
                      onPressed: () => DefaultTabController.of(context).animateTo(1),
                      child: const Text('مراجعة'),
                    ),
                  ),
                ),
              Wrap(spacing: 8, runSpacing: 8, children: [
                KpiCard(
                  label: 'أجهزة بانتظار الموافقة',
                  value: '$pending',
                  icon: Icons.phonelink_lock,
                  color: pending > 0 ? Colors.deepOrange : Colors.green,
                ),
                KpiCard(label: 'جلسات فعّالة', value: '${toInt(d['active_sessions'])}', icon: Icons.vpn_key, color: Colors.indigo),
                KpiCard(
                  label: 'متصلون الآن',
                  value: '${toInt(d['online_now'])}',
                  sub: 'نشاط خلال آخر 10 دقائق',
                  icon: Icons.wifi,
                  color: Colors.teal,
                ),
                KpiCard(
                  label: 'محاولات مشاركة جهاز (7 أيام)',
                  value: '$sharing',
                  icon: Icons.devices_other,
                  color: sharing > 0 ? Colors.red : Colors.green,
                ),
                KpiCard(
                  label: 'إعدادات معدّلة عن الافتراضي',
                  value: '${toInt(d['settings_overridden'])}',
                  icon: Icons.tune,
                  color: Colors.blueGrey,
                ),
                KpiCard(
                  label: 'استثناءات: قواطع / أشخاص',
                  value: '${toInt(d['sector_overrides'])} / ${toInt(d['person_overrides'])}',
                  icon: Icons.rule,
                  color: Colors.purple,
                ),
              ]),
              const SectionTitle('المفاتيح العامة'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in switchLabels.entries)
                  StatusChip(
                    '${e.value}: ${switches[e.key] == true ? 'تعمل' : 'متوقفة'}',
                    switches[e.key] == true ? Colors.green.shade700 : Colors.red.shade700,
                  ),
              ]),
              const SectionTitle('أوضاع النظام'),
              Card(
                child: Column(children: [
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.chat, color: waLive ? Colors.green : Colors.orange),
                    title: const Text('واتساب'),
                    subtitle: Text(waLive ? 'إرسال فعلي' : 'تجريبي (لا يُرسل)'),
                  ),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.percent, color: Colors.indigo),
                    title: const Text('طريقة احتساب نسبة الزيادة'),
                    subtitle: Text(_gainModes[gain] ?? txt(gain)),
                  ),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.verified_user, color: Colors.indigo),
                    title: const Text('موافقة الأجهزة الجديدة'),
                    subtitle: Text(d['device_approval_required'] == true ? 'مطلوبة' : 'غير مطلوبة'),
                  ),
                ]),
              ),
              const SectionTitle('الحسابات حسب الدور'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    const Row(children: [
                      Expanded(flex: 3, child: Text('الدور', style: TextStyle(fontWeight: FontWeight.bold))),
                      Expanded(flex: 2, child: Text('فعّال', style: TextStyle(fontWeight: FontWeight.bold))),
                      Expanded(flex: 2, child: Text('موقوف', style: TextStyle(fontWeight: FontWeight.bold))),
                    ]),
                    const Divider(),
                    if (roles.isEmpty) const EmptyNote('لا توجد حسابات'),
                    for (final r in roles)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          Expanded(flex: 3, child: Text(txt(r['label'] ?? r['role']))),
                          Expanded(flex: 2, child: Text('${toInt(r['active'])}', style: const TextStyle(color: Colors.green))),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '${toInt(r['suspended'])}',
                              style: TextStyle(color: toInt(r['suspended']) > 0 ? Colors.red : Colors.grey),
                            ),
                          ),
                        ]),
                      ),
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
