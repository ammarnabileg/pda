import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/format.dart';
import '../util/ids.dart';
import 'scan_helpers.dart';
import 'scope.dart';
import 'widgets.dart';

class SaleScreen extends StatefulWidget {
  const SaleScreen({super.key});
  @override
  State<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends State<SaleScreen> {
  final List<SaleLine> lines = [];
  final Map<int, Product> products = {};
  bool loaded = false;
  String? flashKey;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppScope.read(context).db;
    final draft = await db.getJson('draft_sale');
    if (draft is Map) {
      lines.addAll((draft['lines'] as List).map((j) => SaleLine.fromJson(j as Map<String, dynamic>)));
    }
    products.addAll(await db.productsByIds(lines.map((l) => l.productId)));
    lines.removeWhere((l) => !products.containsKey(l.productId));
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _save() =>
      AppScope.read(context).db.setJson('draft_sale', lines.isEmpty ? null : {'lines': lines.map((l) => l.toJson()).toList()});

  int get total => lines.fold(0, (a, l) => a + lineTotal(products[l.productId]!.unitPrice(l.mode), l.qty));

  void _add(Product p, String mode, int qty) {
    products[p.id] = p;
    final i = lines.indexWhere((l) => l.productId == p.id && l.mode == mode);
    SaleLine line;
    if (i >= 0) {
      line = lines.removeAt(i)..qty += qty;
    } else {
      line = SaleLine(p.id, mode, qty);
    }
    setState(() {
      lines.add(line);
      flashKey = '${p.id}$mode';
    });
    _save();
    if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  Future<void> _onProduct(Product? p) async {
    if (p == null || !mounted) return;
    if (p.isKg) {
      final r = await numberPad(
        context,
        title: p.name,
        hint: '${money(p.price)} د.ك للكيلو. اكتب الوزن من الميزان',
        modes: const ['kg'],
        ok: 'إضافة',
      );
      if (r?.scanned != null) return _onScan(r!.scanned!);
      if (r != null) _add(p, 'kg', r.qty);
    } else {
      _add(p, 'piece', 1000);
    }
  }

  Future<void> _onScan(String code) async {
    final app = AppScope.read(context);
    await _onProduct(await findScanned(context, app, code));
  }

  Future<void> _editQty(SaleLine l) async {
    final p = products[l.productId]!;
    final r = await numberPad(
      context,
      title: p.name,
      hint: l.mode == 'kg' ? 'اكتب الوزن من الميزان' : 'اكتب الكمية',
      modes: p.modes,
      mode: l.mode,
      initial: l.qty,
    );
    if (r?.scanned != null) return _onScan(r!.scanned!);
    if (r == null) return;
    setState(() {
      final other = lines.indexWhere((x) => !identical(x, l) && x.productId == l.productId && x.mode == r.mode);
      if (other >= 0) {
        lines[other].qty += r.qty;
        lines.remove(l);
      } else {
        l
          ..qty = r.qty
          ..mode = r.mode;
      }
    });
    _save();
  }

  void _delete(SaleLine l) {
    final i = lines.indexOf(l);
    setState(() => lines.removeAt(i));
    _save();
    toast(
      context,
      'تم حذف ${products[l.productId]!.name}',
      undo: () {
        if (!mounted) return;
        setState(() => lines.insert(i.clamp(0, lines.length), l));
        _save();
      },
    );
  }

  Future<void> _clear() async {
    final ok = await confirmSheet(
      context,
      title: 'إلغاء الفاتورة كلها؟',
      body: const Text('سيتم حذف كل الأصناف من الفاتورة.'),
      yes: 'نعم، إلغاء',
      danger: true,
    );
    if (!ok) return;
    setState(() => lines.clear());
    _save();
  }

  Future<void> _finish() async {
    final t = total;
    final ok = await confirmSheet(
      context,
      title: 'إنهاء البيع',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('المبلغ المطلوب من الزبون'),
          Text('${money(t)} د.ك', style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800)),
        ],
      ),
      yes: 'تم الدفع',
    );
    if (!ok || !mounted) return;
    final app = AppScope.read(context);
    final id = uuid4();
    await app.db.enqueue('sales', id, {
      'id': id,
      'employee_id': app.employee?.id,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'lines': [
        for (final l in lines)
          {'product_id': l.productId, 'mode': l.mode, 'qty': money(l.qty), 'unit_price': money(products[l.productId]!.unitPrice(l.mode))},
      ],
    });
    for (final l in lines) {
      await app.db.adjustStock(l.productId, -products[l.productId]!.toBase(l.qty, l.mode));
    }
    lines.clear();
    await _save();
    await app.recordSaved();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => SaleDoneScreen(total: t)));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    Future<void> type() async => _onProduct(await typeAndFind(context, app));
    Future<void> search() async => _onProduct(await searchAndPick(context, app));
    final key = flashKey;
    flashKey = null;
    return ScanListener(
      onScan: _onScan,
      child: Scaffold(
        appBar: topBar(context, 'بيع'),
        body: !loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(12),
                children: [
                  if (lines.isEmpty)
                    ScanPrompt(title: 'امسح باركود الصنف', sub: 'كل مسح يضيف حبة واحدة للفاتورة', onType: type, onSearch: search)
                  else
                    ScanBar(text: 'امسح الصنف التالي', onType: type, onSearch: search),
                  for (final l in lines.reversed) _lineCard(l, '${l.productId}${l.mode}' == key),
                  if (lines.isNotEmpty)
                    TextButton(
                      onPressed: _clear,
                      child: const Text(
                        'إلغاء الفاتورة كلها',
                        style: TextStyle(color: cRed, fontSize: 18, fontWeight: FontWeight.w800, decoration: TextDecoration.underline),
                      ),
                    ),
                ],
              ),
        bottomNavigationBar: Footer(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text('الإجمالي (${lines.length} صنف)', style: const TextStyle(fontSize: 20, color: cMuted)),
                ),
                Text(money(loaded ? total : 0), style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800)),
                const Text(' د.ك', style: TextStyle(fontSize: 20)),
              ],
            ),
            const SizedBox(height: 8),
            BigButton('إنهاء البيع', icon: Icons.check, onPressed: lines.isEmpty ? null : _finish),
          ],
        ),
      ),
    );
  }

  Widget _lineCard(SaleLine l, bool flash) {
    final p = products[l.productId]!;
    final up = p.unitPrice(l.mode);
    final kg = l.mode == 'kg';
    return TweenAnimationBuilder<double>(
      key: ValueKey('${l.productId}${l.mode}${flash ? DateTime.now().microsecondsSinceEpoch : ''}'),
      tween: Tween(begin: flash ? 1 : 0, end: 0),
      duration: const Duration(milliseconds: 1200),
      builder: (_, t, child) =>
          CardBox(color: Color.lerp(Colors.white, const Color(0xFFC9F0D8), t), border: Color.lerp(cLine, cGreen, t)!, child: child!),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, height: 1.3)),
                    Text('${money(up)} د.ك ${perUnit[l.mode]}', style: const TextStyle(fontSize: 17, color: cMuted)),
                  ],
                ),
              ),
              Text(money(lineTotal(up, l.qty)), style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (!kg)
                _step('+', () {
                  setState(() => l.qty += 1000);
                  _save();
                }),
              if (!kg) const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 58,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: cLine, width: 2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      foregroundColor: Colors.black,
                    ),
                    onPressed: () => _editQty(l),
                    child: Text(qtyText(l.qty, l.mode), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
              if (!kg) const SizedBox(width: 8),
              if (!kg)
                _step(
                  '−',
                  l.qty <= 1000
                      ? null
                      : () {
                          setState(() => l.qty -= 1000);
                          _save();
                        },
                ),
              const SizedBox(width: 8),
              SizedBox(
                height: 58,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    backgroundColor: cRed2,
                    foregroundColor: cRed,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => _delete(l),
                  icon: const Icon(Icons.delete_outline, size: 24),
                  label: const Text('حذف', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _step(String t, VoidCallback? f) => SizedBox(
    width: 60,
    height: 58,
    child: FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: cGreen2,
        foregroundColor: cGreen,
        disabledBackgroundColor: cGray2,
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: f,
      child: Text(t, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
    ),
  );
}

class SaleDoneScreen extends StatelessWidget {
  final int total;
  const SaleDoneScreen({super.key, required this.total});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: topBar(context, 'بيع'),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 20),
        const CircleAvatar(
          radius: 60,
          backgroundColor: cGreen,
          child: Icon(Icons.check, size: 70, color: Colors.white),
        ),
        const SizedBox(height: 16),
        const Text(
          'تم البيع',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
        ),
        const Text(
          'المبلغ',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, color: cMuted),
        ),
        Text(
          '${money(total)} د.ك',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 24),
        BigButton(
          'فاتورة جديدة',
          icon: Icons.shopping_cart_outlined,
          onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const SaleScreen())),
        ),
        const SizedBox(height: 10),
        BigButton.light('الرئيسية', onPressed: () => Navigator.of(context).pop()),
      ],
    ),
  );
}
