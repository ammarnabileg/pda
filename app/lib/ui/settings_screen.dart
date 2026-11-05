import 'package:flutter/material.dart';

import '../data/app_state.dart';
import 'price_screen.dart' show syncedAgo;
import 'scope.dart';
import 'widgets.dart';

/// Why the server refused a record, and what to do about it.
const _reasons = {
  'unknown_product': ('فيه صنف اتمسح من السيرفر', 'المشرف يرجّع الصنف أو يسجّل العملية يدوياً من لوحة التحكم.'),
  'bad_line': ('كمية أو وحدة مش مقبولة', 'سجّل العملية تاني بالكمية الصح.'),
  'empty_sale': ('فاتورة فاضية', 'مفيش حاجة مطلوبة.'),
  'empty_count': ('جرد فاضي', 'مفيش حاجة مطلوبة.'),
  'unknown_receipt': ('السند اتمسح من السيرفر', 'راجع المشرف.'),
  'receipt_not_open': ('السند اتلغى أو اتستلم من جهاز تاني', 'المشرف يراجع السند في لوحة التحكم.'),
  'invalid': ('بيانات مش مفهومة', 'بلّغ المسؤول عن السيستم.'),
  'empty_receipt': ('سند فاضي', 'مفيش حاجة مطلوبة.'),
  'no_supplier': ('السند من غير مورد', 'سجّله تاني واختار المورد.'),
  'duplicate_invoice': ('فاتورة الشركة دي اتسجلت قبل كده', 'راجع رقم الفاتورة مع المدير. لو السند اتسجل مرتين، مفيش حاجة مطلوبة.'),
  'receipt_rejected': ('صورة لسند اترفض', 'مفيش حاجة مطلوبة.'),
  'bad_file': ('صورة الفاتورة مش مقبولة', 'صوّرها تاني وابعتها للمدير.'),
};
const _kinds = {'sales': 'بيع', 'counts': 'جرد', 'receipts': 'استلام', 'new_receipts': 'استلام من غير سند', 'receipt_files': 'صورة فاتورة', 'sale_files': 'صورة فاتورة الوزارة'};

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

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final (IconData icon, String title, String sub, Color fg, Color bg) = switch (app.status) {
      SyncStatus.syncing => (Icons.sync, 'جاري ${W.sync}…', 'بيبعت العمليات وينزّل التحديثات', cBlue, cBlue2),
      SyncStatus.ok when rejected.isNotEmpty => (Icons.error_outline, 'متصل — فيه عمليات مرفوضة', 'شوف السبب تحت', cOrange, cOrange2),
      SyncStatus.ok => (Icons.cloud_done_outlined, 'متصل بالسيرفر', 'كل حاجة بتتبعت أول بأول', cGreen, cGreen2),
      SyncStatus.offline => (
        Icons.cloud_off_outlined,
        'غير متصل',
        'كمّل شغلك عادي: البيع والجرد والاستلام بيتحفظوا على الجهاز ويتبعتوا لما الشبكة ترجع.',
        cOrange,
        cOrange2,
      ),
      SyncStatus.unpaired => (Icons.link_off, 'الجهاز غير مربوط', 'المدير يعمل كود ربط جديد من لوحة التحكم ← الأجهزة.', cRed, cRed2),
      SyncStatus.error => (Icons.error_outline, 'السيرفر رد بخطأ', 'الشغل محفوظ على الجهاز. بلّغ المسؤول عن السيستم.', cRed, cRed2),
      SyncStatus.idle => (Icons.cloud_queue, '—', '', cMuted, cGray2),
    };
    final byKind = app.pendingByKind;
    final t = app.lastSync;
    return WorkScaffold(
      title: W.sync,
      body: ListView(
        padding: const EdgeInsets.all(S.edge),
        children: [
          CardBox(
            color: bg,
            border: fg,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: fg, size: 28),
                const SizedBox(width: S.s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: T.heading.copyWith(color: fg)),
                      if (sub.isNotEmpty) Text(sub, style: T.sub.copyWith(color: cInk)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          CardBox(
            child: Column(
              children: [
                _row(
                  'آخر ${W.sync}',
                  t == null
                      ? 'لسه'
                      : '${t.day}/${t.month}/${t.year} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                ),
                _row('', syncedAgo(t)),
                const Divider(height: S.m),
                _row('مستني يتبعت', app.pending == 0 ? 'ولا حاجة' : '${app.pending}'),
                for (final e in byKind.entries) _row('   ${_kinds[e.key] ?? e.key}', '${e.value}'),
                _row('مرفوض', '${app.rejected}'),
                const Divider(height: S.m),
                _row('الأصناف على الجهاز', '${app.productCount}'),
                _row('الجهاز', app.deviceName ?? '—'),
                _row('السيرفر', app.serverUrl ?? '—', ltr: true),
              ],
            ),
          ),
          BigButton(
            app.status == SyncStatus.syncing ? 'جاري ${W.sync}…' : W.syncNow,
            icon: Icons.sync,
            onPressed: app.status == SyncStatus.syncing || !app.paired ? null : () => app.sync(full: true),
          ),
          const Padding(
            padding: EdgeInsets.only(top: S.xs),
            child: Text('${W.sync} بتبعت اللي على الجهاز، وتنزّل الأصناف والأسعار والأرصدة والموظفين والسندات.', style: T.sub),
          ),
          if (rejected.isNotEmpty) ...[
            const SizedBox(height: S.l),
            const Text('عمليات رفضها السيرفر', style: T.heading),
            const Text('محفوظة على الجهاز ومش هتتبعت تاني لوحدها.', style: T.sub),
            const SizedBox(height: S.s),
            for (final r in rejected)
              Builder(
                builder: (_) {
                  final reason = _reasons[r['error']] ?? (r['error'].toString(), 'بلّغ المسؤول عن السيستم.');
                  final at = (r['created_at'] as String).substring(0, 16).replaceFirst('T', ' ');
                  return CardBox(
                    border: cRed,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${_kinds[r['kind']] ?? r['kind']} · $at', style: T.label),
                        Text('السبب: ${reason.$1}', style: T.sub.copyWith(color: cRed)),
                        Text('المطلوب: ${reason.$2}', style: T.sub),
                      ],
                    ),
                  );
                },
              ),
          ],
          if (app.employee?.can('device_admin') == true) ...[
            const SizedBox(height: S.l),
            BigButton.light(
              'فك ربط الجهاز',
              icon: Icons.link_off,
              onPressed: () async {
                final ok = await confirmSheet(
                  context,
                  title: 'فك ربط الجهاز؟',
                  body: Text(
                    app.pending > 0
                        ? 'فيه ${app.pending} عملية لسه ماتبعتتش. هتفضل محفوظة وتتبعت بعد ما الجهاز يتربط تاني.'
                        : 'هتحتاج كود ربط جديد من لوحة التحكم.',
                  ),
                  yes: 'فك الربط',
                  danger: true,
                );
                if (ok && context.mounted) {
                  await app.unpair();
                  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                }
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String k, String v, {bool ltr = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(k, style: T.sub)),
        Flexible(
          child: Text(v, textAlign: TextAlign.left, textDirection: ltr ? TextDirection.ltr : null, style: T.subStrong),
        ),
      ],
    ),
  );
}
