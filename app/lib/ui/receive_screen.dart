import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/feedback.dart';
import '../util/format.dart';
import 'scan_helpers.dart';
import 'scope.dart';
import 'widgets.dart';

const noteChips = ['كرتون تالف', 'كمية ناقصة', 'قريب الانتهاء', 'صنف غير مطابق'];

class ReceiveListScreen extends StatefulWidget {
  const ReceiveListScreen({super.key});
  @override
  State<ReceiveListScreen> createState() => _ReceiveListScreenState();
}

class _ReceiveListScreenState extends State<ReceiveListScreen> {
  List<ReceiptDoc>? items;
  Map<int, int> progress = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AppScope.of(context); // rebuild after each sync
    _load();
  }

  Future<void> _load() async {
    final db = AppScope.read(context).db;
    final list = await db.openReceipts();
    final prog = <int, int>{};
    for (final r in list) {
      final d = await db.getJson('draft_receipt_${r.id}');
      if (d is Map) prog[r.id] = (d['recv'] as Map).keys.where((k) => r.lines.any((l) => '${l.productId}' == k)).length;
    }
    if (mounted) {
      setState(() {
        items = list;
        progress = prog;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScanListener(
      onScan: (_) {
        beepError();
        toast(context, 'افتح السند الأول، وبعدين امسح الصنف');
      },
      child: Scaffold(
        appBar: topBar(context, 'استلام بضاعة'),
        body: items == null
            ? const Center(child: CircularProgressIndicator())
            : items!.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('مفيش سندات بانتظار الاستلام.\nالمشرف بيضيفها من لوحة التحكم.',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 20, color: cMuted)),
                  )
                : ListView(padding: const EdgeInsets.all(12), children: [
                    for (final r in items!)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Material(
                          color: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: cLine, width: 2)),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiveScreen(receiptId: r.id)));
                              _load();
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(r.supplier, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                                Text('سند رقم ${r.id} · ${r.lines.length} أصناف', style: const TextStyle(fontSize: 18, color: cMuted)),
                                const SizedBox(height: 8),
                                (progress[r.id] ?? 0) > 0
                                    ? Pill('تمت مراجعة ${progress[r.id]} من ${r.lines.length}', fg: cOrange, bg: cOrange2)
                                    : const Pill('لم يبدأ'),
                              ]),
                            ),
                          ),
                        ),
                      ),
                  ]),
      ),
    );
  }
}

class _Recv {
  int qty;
  String mode;
  _Recv(this.qty, this.mode);
}

class ReceiveScreen extends StatefulWidget {
  final int receiptId;
  const ReceiveScreen({super.key, required this.receiptId});
  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  ReceiptDoc? r;
  final products = <int, Product>{};
  final recv = <int, _Recv>{};
  final extra = <int>[];
  final notes = <String>[];
  int? flashId;

  String get _key => 'draft_receipt_${widget.receiptId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppScope.read(context).db;
    final doc = await db.receiptById(widget.receiptId);
    final d = await db.getJson(_key);
    if (d is Map) {
      (d['recv'] as Map).forEach((k, v) => recv[int.parse(k as String)] = _Recv(v['q'] as int, v['m'] as String));
      extra.addAll((d['extra'] as List).cast<int>());
      notes.addAll((d['notes'] as List).cast<String>());
    }
    if (doc != null) products.addAll(await db.productsByIds([...doc.lines.map((l) => l.productId), ...extra]));
    if (mounted) setState(() => r = doc);
  }

  Future<void> _save() => AppScope.read(context).db.setJson(_key, {
        'recv': {for (final e in recv.entries) '${e.key}': {'q': e.value.qty, 'm': e.value.mode}},
        'extra': extra,
        'notes': notes,
      });

  ReceiptLine? _line(int pid) {
    for (final l in r!.lines) {
      if (l.productId == pid) return l;
    }
    return null;
  }

  /// (text, fg, bg) or null when not reviewed yet.
  (String, Color, Color)? _status(int pid) {
    final x = recv[pid];
    if (x == null) return null;
    final p = products[pid]!;
    final l = _line(pid);
    if (l == null) return ('صنف زائد غير مطلوب', cBlue, cBlue2);
    final d = p.toBase(x.qty, x.mode) - p.toBase(l.ordered, l.mode);
    if (d == 0) return ('مطابق', cGreen, cGreen2);
    return d < 0 ? ('ناقص ${_diff(p, -d)}', cOrange, cOrange2) : ('زيادة ${_diff(p, d)}', cBlue, cBlue2);
  }

  String _diff(Product p, int base) {
    if (p.isKg) return '${money(base)} كجم';
    if (p.carton > 0 && base % (p.carton * 1000) == 0) return '${base ~/ (p.carton * 1000)} كرتون';
    return '${qty(base, 'piece')} حبة';
  }

  Future<void> _qty(int pid, {bool isExtra = false}) async {
    final p = products[pid]!;
    final l = _line(pid);
    final cur = recv[pid];
    final res = await numberPad(context,
        title: p.name,
        hint: l != null ? 'المطلوب: ${qtyText(l.ordered, l.mode)}. اكتب اللي وصل فعلاً (صفر لو ماوصلش)' : 'صنف غير موجود في السند. اكتب الكمية اللي وصلت',
        modes: p.modes,
        mode: cur?.mode ?? l?.mode ?? p.modes.first,
        initial: cur?.qty,
        allowZero: l != null);
    if (res?.scanned != null) return _onScan(res!.scanned!);
    if (res == null || !mounted) return;
    setState(() {
      if (isExtra && !extra.contains(pid)) extra.add(pid);
      recv[pid] = _Recv(res.qty, res.mode);
      flashId = pid;
    });
    _save();
  }

  void _full(ReceiptLine l) {
    beepOk();
    setState(() {
      recv[l.productId] = _Recv(l.ordered, l.mode);
      flashId = l.productId;
    });
    _save();
  }

  Future<void> _onProduct(Product? p) async {
    if (p == null || !mounted) return;
    products[p.id] = p;
    if (_line(p.id) != null || extra.contains(p.id)) return _qty(p.id);
    beepError();
    final ok = await confirmSheet(context,
        title: 'الصنف ده مش في السند',
        body: Text('${p.name}\nغير مطلوب من المورد في هذا السند.'),
        yes: 'أضفه كصنف زائد',
        no: 'إلغاء',
        danger: true);
    if (ok) await _qty(p.id, isExtra: true);
  }

  Future<void> _onScan(String code) async {
    final app = AppScope.read(context);
    final p = await app.db.productByBarcode(code);
    if (p == null) {
      if (mounted) await findScanned(context, app, code); // shows the "not registered" message
      return;
    }
    if (_line(p.id) != null || extra.contains(p.id)) beepOk();
    await _onProduct(p);
  }

  Future<void> _finish() async {
    final left = r!.lines.where((l) => !recv.containsKey(l.productId)).toList();
    if (left.isNotEmpty) {
      beepError();
      await alertSheet(context,
          title: 'باقي ${left.length} أصناف لم تراجع',
          body: Text('${left.map((l) => '• ${products[l.productId]?.name ?? ''}').join('\n')}\n\nاضغط «وصل كامل» أو «كمية مختلفة» لكل صنف.'));
      return;
    }
    final diffs = [...r!.lines.map((l) => l.productId), ...extra].where((pid) => _status(pid)!.$2 != cGreen).toList();
    final ok = await confirmSheet(context,
        title: 'تأكيد الاستلام؟',
        body: Text(diffs.isEmpty
            ? 'كل الأصناف مطابقة للمطلوب.'
            : 'فيه فروقات في ${diffs.length} صنف:\n${diffs.map((pid) => '• ${products[pid]!.name}: ${_status(pid)!.$1}').join('\n')}'),
        yes: 'نعم، تأكيد');
    if (!ok || !mounted) return;
    final app = AppScope.read(context);
    await app.db.enqueue('receipts', '${r!.id}', {
      'receipt_id': r!.id,
      'employee_id': app.employee?.id,
      'received_at': DateTime.now().toUtc().toIso8601String(),
      'notes': notes.join('، '),
      'lines': [
        for (final e in recv.entries) {'product_id': e.key, 'mode': e.value.mode, 'qty': money(e.value.qty)}
      ],
    });
    for (final e in recv.entries) {
      await app.db.adjustStock(e.key, products[e.key]!.toBase(e.value.qty, e.value.mode));
    }
    await app.db.markReceiptSent(r!.id);
    await app.db.set(_key, null);
    await app.recordSaved();
    if (!mounted) return;
    Navigator.of(context).pop();
    toast(context, 'تم تأكيد استلام السند ${r!.id}');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final doc = r;
    final flash = flashId;
    flashId = null;
    if (doc == null) return Scaffold(appBar: topBar(context, 'سند'), body: const Center(child: CircularProgressIndicator()));
    final reviewed = doc.lines.where((l) => recv.containsKey(l.productId)).length;
    final all = [...doc.lines.map((l) => l.productId), ...extra];
    return ScanListener(
      onScan: _onScan,
      child: Scaffold(
        appBar: topBar(context, 'سند ${doc.id}'),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          CardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(doc.supplier, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              Text('تمت مراجعة $reviewed من ${doc.lines.length} أصناف', style: const TextStyle(fontSize: 17, color: cMuted)),
              if (doc.note.isNotEmpty) Text('ملاحظة: ${doc.note}', style: const TextStyle(fontSize: 17)),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                    value: doc.lines.isEmpty ? 0 : reviewed / doc.lines.length, minHeight: 12, backgroundColor: cGray2, color: cGreen),
              ),
            ]),
          ),
          ScanBar(
              text: 'امسح الصنف لتسجيل كميته',
              onType: () async => _onProduct(await typeAndFind(context, app)),
              onSearch: () async => _onProduct(await searchAndPick(context, app))),
          for (final pid in all) _lineCard(pid, pid == flash),
          const Padding(
            padding: EdgeInsets.fromLTRB(2, 10, 2, 6),
            child: Text('ملاحظات (اختياري)', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final n in noteChips)
              FilterChip(
                label: Text(n, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                selected: notes.contains(n),
                selectedColor: cOrange2,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                onSelected: (on) {
                  setState(() => on ? notes.add(n) : notes.remove(n));
                  _save();
                },
              ),
          ]),
        ]),
        bottomNavigationBar: Footer(children: [BigButton('تأكيد الاستلام', icon: Icons.check, onPressed: _finish)]),
      ),
    );
  }

  Widget _lineCard(int pid, bool flash) {
    final p = products[pid];
    if (p == null) {
      return const CardBox(child: Text('صنف غير موجود على الجهاز. اعمل مزامنة.', style: TextStyle(fontSize: 18, color: cRed)));
    }
    final l = _line(pid);
    final x = recv[pid];
    final s = _status(pid);
    return CardBox(
      border: flash ? cGreen : (s?.$2 ?? cLine),
      color: flash ? const Color(0xFFE9F7EE) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(p.name, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
          s == null ? const Pill('لم يراجع') : Pill(s.$1, fg: s.$2, bg: s.$3),
        ]),
        if (l != null)
          Text('المطلوب: ${qtyText(l.ordered, l.mode)}${l.mode == 'carton' ? ' (${qty(l.ordered * p.carton, 'piece')} حبة)' : ''}',
              style: const TextStyle(fontSize: 18)),
        if (x != null) Text('المستلم: ${qtyText(x.qty, x.mode)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        if (x != null)
          BigButton.light('تعديل الكمية', icon: Icons.edit_outlined, height: 58, onPressed: () => _qty(pid))
        else
          Row(children: [
            Expanded(child: BigButton('وصل كامل', icon: Icons.check, height: 58, onPressed: l == null ? null : () => _full(l))),
            const SizedBox(width: 8),
            Expanded(child: BigButton.light('كمية مختلفة', height: 58, onPressed: () => _qty(pid))),
          ]),
      ]),
    );
  }
}
