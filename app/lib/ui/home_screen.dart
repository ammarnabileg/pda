import 'package:flutter/material.dart';

import 'count_screen.dart';
import 'history_screen.dart';
import 'price_screen.dart';
import 'receive_screen.dart';
import 'sale_screen.dart';
import 'scan_helpers.dart';
import 'scope.dart';
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
    final h = await findScanned(context, app, code);
    if (h != null && mounted) _open(PriceScreen(initial: h));
  }

  Future<void> _switchUser() async {
    final app = AppScope.read(context);
    if (saleItems > 0 || countItems > 0) {
      final ok = await confirmSheet(
        context,
        title: '${W.switchUser}؟',
        body: const Text('الفاتورة أو الجرد المفتوح هيفضل محفوظ على الجهاز، والموظف اللي بعدك هيلاقيه.'),
        yes: W.switchUser,
      );
      if (!ok) return;
    }
    app.logout();
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
          titleSpacing: S.m,
          title: const Row(
            children: [
              Icon(Icons.diamond_outlined, size: 24),
              SizedBox(width: S.s),
              Expanded(child: Text('تموين', style: T.pageTitle)),
              SyncIndicator(),
            ],
          ),
        ),
        body: Column(
          children: [
            const OfflineStrip(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(S.edge),
                children: [
                  if (app.rejected > 0 && e.isSupervisor)
                    CardBox(
                      color: cOrange2,
                      border: cOrange,
                      child: Text(
                        '${app.rejected} عملية رفضها السيرفر. افتح «${W.sync}» لمعرفة السبب.',
                        style: T.label.copyWith(color: cOrange),
                      ),
                    ),
                  Row(
                    children: [
                      const Icon(Icons.person_outline, size: 22, color: cMuted),
                      const SizedBox(width: S.xs),
                      Expanded(
                        child: Text('${e.name} · ${roleName(e.role)}', style: T.label, overflow: TextOverflow.ellipsis),
                      ),
                      TextButton.icon(
                        onPressed: _switchUser,
                        icon: const Icon(Icons.switch_account_outlined, size: 22),
                        label: const Text(W.switchUser, style: T.label),
                      ),
                    ],
                  ),
                  const SizedBox(height: S.xs),
                  if (e.canSell)
                    _MenuItem(
                      title: 'بيع',
                      sub: 'فاتورة للزبون',
                      icon: Icons.shopping_cart_outlined,
                      main: true,
                      badge: saleItems > 0 ? 'فاتورة مفتوحة: $saleItems صنف' : null,
                      onTap: () => _open(const SaleScreen()),
                    ),
                  _MenuItem(
                    title: 'سعر صنف',
                    sub: 'امسح أي صنف من هنا لمعرفة سعره',
                    icon: Icons.sell_outlined,
                    onTap: () => _open(const PriceScreen()),
                  ),
                  if (e.canStock) ...[
                    _MenuItem(
                      title: 'جرد',
                      sub: 'عدّ البضاعة على الرف',
                      icon: Icons.fact_check_outlined,
                      badge: countItems > 0 ? 'جرد مفتوح: $countItems صنف' : null,
                      onTap: () => _open(const CountScreen()),
                    ),
                    _MenuItem(
                      title: 'استلام',
                      sub: 'بضاعة من المورد',
                      icon: Icons.local_shipping_outlined,
                      badge: openReceipts > 0 ? '$openReceipts سند مستني' : null,
                      onTap: () => _open(const ReceiveListScreen()),
                    ),
                  ],
                  const SizedBox(height: S.xs),
                  const Text('السجل (على الجهاز ده)', style: T.label),
                  const SizedBox(height: S.xs),
                  Wrap(
                    spacing: S.s,
                    runSpacing: S.s,
                    children: [
                      if (e.canSell) _historyButton(Icons.receipt_long_outlined, 'الفواتير', 'sales'),
                      if (e.canStock) _historyButton(Icons.local_shipping_outlined, 'السندات المستلمة', 'receipts'),
                      if (e.canStock) _historyButton(Icons.fact_check_outlined, 'الجرد', 'counts'),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _historyButton(IconData icon, String label, String kind) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, S.touch),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(S.radius)),
    ),
    onPressed: () => _open(HistoryScreen(kind: kind)),
    icon: Icon(icon, size: 20),
    label: Text(label, style: T.label),
  );
}

String roleName(String role) => const {'cashier': 'كاشير', 'storekeeper': 'أمين مخزن', 'supervisor': 'مشرف', 'admin': 'مدير'}[role] ?? role;

class _MenuItem extends StatelessWidget {
  final String title, sub;
  final String? badge;
  final IconData icon;
  final bool main;
  final VoidCallback onTap;
  const _MenuItem({required this.title, required this.sub, required this.icon, required this.onTap, this.badge, this.main = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: S.s),
    child: Material(
      color: main ? cPrimary : cSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(S.radius),
        side: main ? BorderSide.none : const BorderSide(color: cLine),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(S.radius),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: main ? 84 : 68),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.m, vertical: S.s),
            child: Row(
              children: [
                Icon(icon, size: main ? 34 : 28, color: main ? Colors.white : cHead),
                const SizedBox(width: S.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: T.heading.copyWith(fontSize: main ? 22 : 19, color: main ? Colors.white : cInk),
                      ),
                      Text(sub, style: T.sub.copyWith(color: main ? Colors.white70 : cMuted)),
                      if (badge != null) ...[const SizedBox(height: S.xs), Pill(badge!, fg: cOrange, bg: cOrange2, icon: Icons.edit_note)],
                    ],
                  ),
                ),
                Icon(Icons.chevron_left, color: main ? Colors.white : cMuted),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
