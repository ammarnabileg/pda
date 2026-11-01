import 'package:flutter/material.dart';

import '../data/app_state.dart';
import 'count_screen.dart';
import 'price_screen.dart';
import 'receive_screen.dart';
import 'sale_screen.dart';
import 'scan_helpers.dart';
import 'scope.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int saleItems = 0, countItems = 0, openReceipts = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _badges();
  }

  Future<void> _badges() async {
    final db = AppScope.read(context).db;
    final sale = await db.getJson('draft_sale');
    final count = await db.getJson('draft_count');
    final rec = await db.openReceipts();
    if (!mounted) return;
    setState(() {
      saleItems = sale is Map ? ((sale['lines'] as List?)?.length ?? 0) : 0;
      countItems = count is Map ? ((count['lines'] as List?)?.length ?? 0) : 0;
      openReceipts = rec.length;
    });
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _badges();
  }

  Future<void> _onScan(String code) async {
    final app = AppScope.read(context);
    final p = await findScanned(context, app, code);
    if (p != null && mounted) _open(PriceScreen(initial: p));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final e = app.employee!;
    return ScanListener(
      onScan: _onScan,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          titleSpacing: 12,
          title: Row(children: [
            const Icon(Icons.diamond_outlined, size: 28),
            const SizedBox(width: 8),
            const Text('تموين', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
            const SizedBox(width: 12),
            const Spacer(),
            Flexible(flex: 6, child: _SyncChip(app: app, onTap: () => _open(const SettingsScreen()))),
          ]),
        ),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          if (app.status == SyncStatus.unpaired)
            _Banner(
                color: cRed,
                bg: cRed2,
                text: 'الجهاز اتفصل من السيرفر. البيع شغال عادي، بس البيانات مش هتتبعت. كلّم المدير يربطه تاني.'),
          if (app.rejected > 0 && e.isSupervisor)
            _Banner(color: cOrange, bg: cOrange2, text: '${app.rejected} عملية رفضها السيرفر. افتح «المزامنة» لمعرفة السبب.'),
          Row(children: [
            Expanded(
                child: Text('أهلاً ${e.name}',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis)),
            TextButton.icon(
              onPressed: () async {
                if (saleItems > 0 || countItems > 0) {
                  final ok = await confirmSheet(context,
                      title: 'تغيير الموظف؟',
                      body: const Text('الفاتورة أو الجرد المفتوح هيفضل محفوظ للموظف اللي بعدك.'),
                      yes: 'خروج');
                  if (!ok) return;
                }
                app.logout();
              },
              icon: const Icon(Icons.logout, size: 24),
              label: const Text('خروج', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            ),
          ]),
          const SizedBox(height: 8),
          if (e.canSell)
            _MenuItem(
                title: 'بيع',
                sub: 'فاتورة للزبون',
                icon: Icons.shopping_cart_outlined,
                fg: cGreen,
                bg: const Color(0xFFDFF1E6),
                badge: saleItems > 0 ? 'فاتورة مفتوحة: $saleItems صنف' : null,
                onTap: () => _open(const SaleScreen())),
          _MenuItem(
              title: 'سعر صنف',
              sub: 'امسح الصنف واعرف سعره',
              icon: Icons.sell_outlined,
              fg: const Color(0xFF8A4B00),
              bg: const Color(0xFFFFF0D6),
              onTap: () => _open(const PriceScreen())),
          if (e.canStock) ...[
            _MenuItem(
                title: 'جرد',
                sub: 'عدّ البضاعة على الرف',
                icon: Icons.fact_check_outlined,
                fg: cBlue,
                bg: const Color(0xFFE4ECFB),
                badge: countItems > 0 ? 'جرد مفتوح: $countItems صنف' : null,
                onTap: () => _open(const CountScreen())),
            _MenuItem(
                title: 'استلام بضاعة',
                sub: 'من المورد',
                icon: Icons.local_shipping_outlined,
                fg: const Color(0xFF6A2FB3),
                bg: const Color(0xFFEFE6FA),
                badge: openReceipts > 0 ? '$openReceipts سند بانتظار الاستلام' : null,
                onTap: () => _open(const ReceiveListScreen())),
          ],
          const SizedBox(height: 10),
          const Text('امسح أي صنف من هنا لمعرفة سعره مباشرة',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 17, color: cMuted)),
        ]),
      ),
    );
  }
}

class _SyncChip extends StatelessWidget {
  final AppState app;
  final VoidCallback onTap;
  const _SyncChip({required this.app, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final (String text, Color bg, Color fg) = switch (app.status) {
      SyncStatus.syncing => ('مزامنة…', Colors.white24, Colors.white),
      SyncStatus.ok => (app.pending > 0 ? 'باقي ${app.pending}' : 'متصل', Colors.white24, Colors.white),
      SyncStatus.offline => ('غير متصل${app.pending > 0 ? ' · ${app.pending}' : ''}', const Color(0xFFF4C7C3), cRed),
      SyncStatus.unpaired => ('غير مربوط', const Color(0xFFF4C7C3), cRed),
      SyncStatus.error => ('خطأ في السيرفر', const Color(0xFFF4C7C3), cRed),
      SyncStatus.idle => ('…', Colors.white24, Colors.white),
    };
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: fg)),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final Color color, bg;
  final String text;
  const _Banner({required this.color, required this.bg, required this.text});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14), border: Border.all(color: color, width: 2)),
        child: Text(text, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w800)),
      );
}

class _MenuItem extends StatelessWidget {
  final String title, sub;
  final String? badge;
  final IconData icon;
  final Color fg, bg;
  final VoidCallback onTap;
  const _MenuItem(
      {required this.title, required this.sub, required this.icon, required this.fg, required this.bg, required this.onTap, this.badge});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: cLine, width: 2)),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 100),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  Container(
                      width: 62,
                      height: 62,
                      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
                      child: Icon(icon, size: 34, color: fg)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w800, height: 1.2)),
                      Text(sub, style: const TextStyle(fontSize: 17, color: cMuted)),
                      if (badge != null) ...[const SizedBox(height: 4), Pill(badge!, fg: cOrange, bg: cOrange2)],
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

