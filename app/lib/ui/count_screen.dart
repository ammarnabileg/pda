import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/format.dart';
import '../util/ids.dart';
import 'scan_helpers.dart';
import 'scope.dart';
import 'widgets.dart';

class _CountLine {
  final int productId;
  int base; // thousandths of the base unit
  _CountLine(this.productId, this.base);
}

/// Blind count: staff see what they counted, not what the system expects.
/// Differences are reviewed and approved by a supervisor in the dashboard.
class CountScreen extends StatefulWidget {
  const CountScreen({super.key});
  @override
  State<CountScreen> createState() => _CountScreenState();
}

class _CountScreenState extends State<CountScreen> {
  final lines = <_CountLine>[];
  final products = <int, Product>{};
  String? id, startedAt;
  bool loaded = false;
  int? flashId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppScope.read(context).db;
    final d = await db.getJson('draft_count');
    if (d is Map) {
      id = d['id'] as String?;
      startedAt = d['started_at'] as String?;
      for (final j in d['lines'] as List) {
        lines.add(_CountLine(j['p'] as int, j['b'] as int));
      }
    }
    products.addAll(await db.productsByIds(lines.map((l) => l.productId)));
    lines.removeWhere((l) => !products.containsKey(l.productId));
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _save() {
    id ??= uuid4();
    startedAt ??= DateTime.now().toUtc().toIso8601String();
    return AppScope.read(context).db.setJson(
      'draft_count',
      lines.isEmpty
          ? null
          : {
              'id': id,
              'started_at': startedAt,
              'lines': [
                for (final l in lines) {'p': l.productId, 'b': l.base},
              ],
            },
    );
  }

  Future<void> _onProduct(Product? p) async {
    if (p == null || !mounted) return;
    products[p.id] = p;
    final i = lines.indexWhere((l) => l.productId == p.id);
    final prev = i >= 0 ? lines[i].base : 0;
    final r = await numberPad(
      context,
      title: p.name,
      hint: prev > 0 ? 'معدود قبل كده: ${p.baseText(prev)}\nالعدد الجديد هيتجمع عليه' : 'اكتب العدد الموجود على الرف',
      modes: p.modes,
    );
    if (r?.scanned != null) return _onScan(r!.scanned!);
    if (r == null || !mounted) return;
    final add = p.toBase(r.qty, r.mode);
    _CountLine line;
    if (i >= 0) {
      line = lines.removeAt(i)..base += add;
    } else {
      line = _CountLine(p.id, add);
    }
    setState(() {
      lines.add(line);
      flashId = p.id;
    });
    _save();
    toast(context, 'تم الحفظ. المجموع: ${p.baseText(line.base)}');
  }

  Future<void> _onScan(String code) async => _onProduct(await findScanned(context, AppScope.read(context), code));

  Future<void> _edit(_CountLine l) async {
    final p = products[l.productId]!;
    final r = await numberPad(
      context,
      title: p.name,
      hint: 'العدد الجديد هيحل محل القديم',
      modes: p.modes,
      mode: p.isKg ? 'kg' : 'piece',
      initial: l.base,
    );
    if (r?.scanned != null) return _onScan(r!.scanned!);
    if (r == null) return;
    setState(() => l.base = p.toBase(r.qty, r.mode));
    _save();
  }

  void _delete(_CountLine l) {
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

  Future<void> _finish() async {
    final ok = await confirmSheet(
      context,
      title: 'إنهاء الجرد؟',
      body: Text('تم عدّ ${lines.length} صنف.\nبعد الإنهاء الجرد هيتبعت للمشرف ومش هتقدر تعدّل.'),
      yes: 'نعم، إنهاء',
    );
    if (!ok || !mounted) return;
    final app = AppScope.read(context);
    await _save();
    await app.db.enqueue('counts', id!, {
      'id': id,
      'employee_id': app.employee?.id,
      'started_at': startedAt,
      'finished_at': DateTime.now().toUtc().toIso8601String(),
      'lines': [
        for (final l in lines) {'product_id': l.productId, 'counted': money(l.base)},
      ],
    });
    final n = lines.length;
    lines.clear();
    id = null;
    startedAt = null;
    await app.db.set('draft_count', null);
    await app.recordSaved();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => _CountDone(count: n)));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    Future<void> type() async => _onProduct(await typeAndFind(context, app));
    Future<void> search() async => _onProduct(await searchAndPick(context, app));
    final flash = flashId;
    flashId = null;
    return ScanListener(
      onScan: _onScan,
      child: Scaffold(
        appBar: topBar(context, 'جرد'),
        body: !loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (lines.isEmpty)
                    ScanPrompt(title: 'امسح باركود الصنف', sub: 'بعدها اكتب العدد الموجود على الرف', onType: type, onSearch: search)
                  else
                    ScanBar(text: 'امسح الصنف التالي', onType: type, onSearch: search),
                  for (final l in lines.reversed)
                    CardBox(
                      border: l.productId == flash ? cGreen : cLine,
                      color: l.productId == flash ? const Color(0xFFE9F7EE) : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(products[l.productId]!.name, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text(
                            'العدد: ${products[l.productId]!.baseText(l.base)}',
                            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: BigButton.light('تعديل العدد', icon: Icons.edit_outlined, height: 58, onPressed: () => _edit(l)),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 110,
                                child: BigButton(
                                  'حذف',
                                  icon: Icons.delete_outline,
                                  color: cRed2,
                                  textColor: cRed,
                                  height: 58,
                                  onPressed: () => _delete(l),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
        bottomNavigationBar: Footer(
          children: [BigButton('إنهاء الجرد (${lines.length} صنف)', icon: Icons.check, onPressed: lines.isEmpty ? null : _finish)],
        ),
      ),
    );
  }
}

class _CountDone extends StatelessWidget {
  final int count;
  const _CountDone({required this.count});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: topBar(context, 'جرد'),
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
          'تم حفظ الجرد',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
        ),
        Text(
          '$count صنف · اتبعت للمشرف للمراجعة',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, color: cMuted),
        ),
        const SizedBox(height: 24),
        BigButton.light('الرئيسية', onPressed: () => Navigator.of(context).pop()),
      ],
    ),
  );
}
