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
  int scans; // how many times it was counted (added to)
  _CountLine(this.productId, this.base, [this.scans = 1]);
}

enum _Sort { recent, name }

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
  int? lastId;
  String? lastNote;
  String filter = '';
  _Sort sort = _Sort.recent;

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
        lines.add(_CountLine(j['p'] as int, j['b'] as int, (j['n'] as int?) ?? 1));
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
                for (final l in lines) {'p': l.productId, 'b': l.base, 'n': l.scans},
              ],
            },
    );
  }

  Future<void> _onProduct(ScanHit? h) async {
    if (h == null || !mounted) return;
    final p = h.product;
    products[p.id] = p;
    final i = lines.indexWhere((l) => l.productId == p.id);
    final prev = i >= 0 ? lines[i].base : 0;
    final r = await numberPad(
      context,
      title: p.name,
      hint: prev > 0 ? 'معدود قبل كده: ${p.baseText(prev)} — العدد الجديد هيتجمع عليه' : 'اكتب العدد الموجود على الرف',
      modes: p.modes,
      mode: h.mode == 'carton' && p.carton > 0 ? 'carton' : null, // carton barcode: counting cartons
      carton: p.carton,
      preview: prev > 0
          ? (q, m) => 'المجموع هيبقى: ${p.baseText(prev + p.toBase(q, m))}'
          : (q, m) => m == 'carton' ? '= ${p.baseText(p.toBase(q, m))}' : null,
    );
    if (r?.scanned != null) return _onScan(r!.scanned!);
    if (r == null || !mounted) return;
    final add = p.toBase(r.qty, r.mode);
    _CountLine line;
    if (i >= 0) {
      line = lines.removeAt(i)
        ..base += add
        ..scans += 1;
    } else {
      line = _CountLine(p.id, add);
    }
    setState(() {
      lines.add(line);
      lastId = p.id;
      lastNote = i >= 0 ? '+${p.baseText(add)}' : null;
      filter = '';
    });
    _save();
  }

  Future<void> _onScan(String code) async => _onProduct(await findScanned(context, AppScope.read(context), code));

  Future<void> _edit(_CountLine l) async {
    final p = products[l.productId]!;
    final r = await numberPad(
      context,
      title: p.name,
      hint: 'العدد الحالي: ${p.baseText(l.base)} — العدد الجديد هيحل محله',
      modes: p.modes,
      mode: p.isKg ? 'kg' : 'piece',
      initial: l.base,
      carton: p.carton,
      preview: (q, m) => 'العدد هيبقى: ${p.baseText(p.toBase(q, m))}',
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

  Future<void> _actions(_CountLine l) async {
    final p = products[l.productId]!;
    final a = await showAppSheet<String>(
      context,
      Builder(
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: T.heading),
            Text('المعدود: ${p.baseText(l.base)}${l.scans > 1 ? ' (على ${l.scans} مرات)' : ''}', style: T.sub),
            const SizedBox(height: S.m),
            BigButton.light('تعديل العدد', icon: Icons.edit_outlined, onPressed: () => Navigator.pop(ctx, 'edit')),
            const SizedBox(height: S.s),
            BigButton.danger('حذف من الجرد', icon: Icons.delete_outline, onPressed: () => Navigator.pop(ctx, 'delete')),
          ],
        ),
      ),
    );
    if (a == 'edit') await _edit(l);
    if (a == 'delete') _delete(l);
  }

  Future<void> _finish() async {
    final ok = await confirmSheet(
      context,
      title: 'إنهاء الجرد؟',
      body: Text('تم عدّ ${lines.length} صنف.\nبعد الإنهاء الجرد بيتقفل، ومش هتقدر تعدّل فيه من الجهاز.'),
      yes: 'نعم، إنهاء',
    );
    if (!ok || !mounted) return;
    final app = AppScope.read(context);
    await _save();
    final countId = id!;
    await app.db.enqueue('counts', countId, {
      'id': countId,
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
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => _CountDone(count: n, id: countId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    Future<void> type() async => _onProduct(await typeAndFind(context, app));
    Future<void> search() async => _onProduct(await searchAndPick(context, app));
    var shown = lines.reversed.where((l) => filter.isEmpty || products[l.productId]!.name.contains(filter)).toList();
    if (sort == _Sort.name) shown.sort((a, b) => products[a.productId]!.name.compareTo(products[b.productId]!.name));
    return WorkScaffold(
      title: 'جرد',
      onScan: _onScan,
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(S.edge),
              children: [
                if (lines.isEmpty)
                  ScanPrompt(title: 'امسح أول صنف لبدء الجرد', sub: 'بعدها اكتب العدد الموجود على الرف', onType: type, onSearch: search)
                else ...[
                  ScanBar(text: 'امسح الصنف التالي', onType: type, onSearch: search),
                  Row(
                    children: [
                      Text('${lines.length} صنف معدود', style: T.subStrong),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => setState(() => sort = sort == _Sort.recent ? _Sort.name : _Sort.recent),
                        icon: const Icon(Icons.swap_vert, size: 20),
                        label: Text(sort == _Sort.recent ? 'الأحدث' : 'بالاسم', style: T.label),
                      ),
                    ],
                  ),
                  const SizedBox(height: S.s),
                  if (lines.length >= 8)
                    Padding(
                      padding: const EdgeInsets.only(bottom: S.s),
                      child: TextField(
                        onChanged: (v) => setState(() => filter = v.trim()),
                        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'دوّر في الجرد',
                          filled: true,
                          fillColor: cSurface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(S.radius),
                            borderSide: const BorderSide(color: cLine),
                          ),
                        ),
                      ),
                    ),
                ],
                for (final l in shown) _row(l),
              ],
            ),
      footer: Footer(
        children: [BigButton('إنهاء الجرد (${lines.length} صنف)', icon: Icons.check, onPressed: lines.isEmpty ? null : _finish)],
      ),
    );
  }

  Widget _row(_CountLine l) {
    final p = products[l.productId]!;
    final isLast = l.productId == lastId;
    return ItemRow(
      key: ValueKey(l.productId),
      title: p.name,
      highlight: isLast,
      onTap: () => _actions(l),
      badge: isLast && lastNote != null ? Pill('اتضاف $lastNote', fg: cGreen, bg: cSurface, icon: Icons.add) : null,
      details: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'المعدود: '),
            TextSpan(text: p.baseText(l.base), style: T.subStrong),
          ],
        ),
      ),
      controls: IconBox(Icons.edit_outlined, label: 'تعديل العدد', onPressed: () => _edit(l)),
    );
  }
}

class _CountDone extends StatelessWidget {
  final int count;
  final String id;
  const _CountDone({required this.count, required this.id});
  @override
  Widget build(BuildContext context) {
    final now = TimeOfDay.now();
    return WorkScaffold(
      title: 'جرد',
      body: ListView(
        padding: const EdgeInsets.all(S.l),
        children: [
          const SizedBox(height: S.m),
          const CircleAvatar(
            radius: 40,
            backgroundColor: cGreen,
            child: Icon(Icons.check, size: 48, color: Colors.white),
          ),
          const SizedBox(height: S.m),
          const Text('تم حفظ الجرد', textAlign: TextAlign.center, style: T.heading),
          Text(
            '$count صنف · الساعة ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
            textAlign: TextAlign.center,
            style: T.sub,
          ),
          const SizedBox(height: S.m),
          Center(child: SendStatus(outboxKey: 'counts:$id')),
          const SizedBox(height: S.xs),
          const Text('بعد ما يتبعت، المشرف بيراجعه ويعتمده من لوحة التحكم.', textAlign: TextAlign.center, style: T.sub),
          const SizedBox(height: S.l),
          BigButton.light('الرئيسية', onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}
