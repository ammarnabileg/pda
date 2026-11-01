import 'package:flutter/material.dart';

import '../data/app_state.dart';
import 'scope.dart';
import 'widgets.dart';

const _reasons = {
  'unknown_product': 'فيه صنف مش موجود على السيرفر',
  'bad_line': 'كمية أو وحدة غلط',
  'empty_sale': 'فاتورة فاضية',
  'empty_count': 'جرد فاضي',
  'unknown_receipt': 'السند مش موجود على السيرفر',
  'receipt_not_open': 'السند اتلغى أو اتستلم من جهاز تاني',
  'invalid': 'بيانات غير مفهومة',
};
const _kinds = {'sales': 'فاتورة بيع', 'counts': 'جرد', 'receipts': 'استلام'};

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<Map<String, Object?>> rejected = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AppScope.of(context);
    AppScope.read(context).db.rejectedOutbox().then((r) {
      if (mounted) setState(() => rejected = r);
    });
  }

  String _ago(DateTime? t) {
    if (t == null) return 'لسه';
    final m = DateTime.now().difference(t).inMinutes;
    return m < 1 ? 'الآن' : 'من $m دقيقة';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final status = switch (app.status) {
      SyncStatus.syncing => 'جاري المزامنة…',
      SyncStatus.ok => 'متصل بالسيرفر',
      SyncStatus.offline => 'مش قادر يوصل للسيرفر. البيع شغال والبيانات هتتبعت لما الشبكة ترجع.',
      SyncStatus.unpaired => 'الجهاز اتفصل من لوحة التحكم. لازم يتربط تاني.',
      SyncStatus.error => 'السيرفر رد بخطأ. كلّم المسؤول.',
      SyncStatus.idle => '—',
    };
    return Scaffold(
      appBar: topBar(context, 'المزامنة'),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        CardBox(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(status, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            _row('الجهاز', app.deviceName ?? '—'),
            _row('السيرفر', app.serverUrl ?? '—'),
            _row('آخر مزامنة', _ago(app.lastSync)),
            _row('مستني يتبعت', '${app.pending}'),
            _row('الأصناف على الجهاز', '${app.productCount}'),
          ]),
        ),
        BigButton(app.status == SyncStatus.syncing ? 'جاري المزامنة…' : 'مزامنة الآن', icon: Icons.sync,
            onPressed: app.status == SyncStatus.syncing || !app.paired ? null : () => app.sync(full: true)),
        if (rejected.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('عمليات رفضها السيرفر', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: cRed)),
          const Text('دي محفوظة على الجهاز ومش هتتبعت. راجعها مع المدير.', style: TextStyle(fontSize: 17, color: cMuted)),
          const SizedBox(height: 8),
          for (final r in rejected)
            CardBox(
              border: cRed,
              child: Text('${_kinds[r['kind']] ?? r['kind']} · ${(r['created_at'] as String).substring(0, 16).replaceFirst('T', ' ')}\n'
                  '${_reasons[r['error']] ?? r['error']}',
                  style: const TextStyle(fontSize: 18)),
            ),
        ],
        if (app.employee?.isSupervisor == true) ...[
          const SizedBox(height: 24),
          BigButton.light('فك ربط الجهاز (للمشرف)', icon: Icons.link_off, onPressed: () async {
            final ok = await confirmSheet(context,
                title: 'فك ربط الجهاز؟',
                body: Text(app.pending > 0
                    ? 'فيه ${app.pending} عملية لسه ماتبعتتش. هتفضل محفوظة وتتبعت بعد ما الجهاز يتربط تاني.'
                    : 'هتحتاج كود ربط جديد من لوحة التحكم.'),
                yes: 'فك الربط',
                danger: true);
            if (ok && context.mounted) {
              await app.unpair();
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            }
          }),
        ],
      ]),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(k, style: const TextStyle(fontSize: 18, color: cMuted))),
          Flexible(child: Text(v, textAlign: TextAlign.left, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
        ]),
      );
}
