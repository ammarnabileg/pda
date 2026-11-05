import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/feedback.dart';
import '../util/format.dart';
import 'history_screen.dart';
import 'new_receipt_screen.dart';
import 'scan_helpers.dart';
import 'scope.dart';
import 'widgets.dart';

const noteChips = ['كرتون تالف', 'كمية ناقصة', 'قريب الانتهاء', 'صنف غير مطابق'];

String _date(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  return d == null ? '' : '${d.day}/${d.month}/${d.year}';
}

class ReceiveListScreen extends StatefulWidget {
  const ReceiveListScreen({super.key});
  @override
  State<ReceiveListScreen> createState() => _ReceiveListScreenState();
}

class _ReceiveListScreenState extends State<ReceiveListScreen> {
  List<ReceiptDoc>? items;
  Map<int, int> progress = {};
  String query = '';
  bool newestFirst = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    AppScope.of(context); // rebuild after each sync
    _load();
  }

  Future<void> _load() async {
    final app = AppScope.read(context);
    final db = app.db;
    // Without «receive» the employee only records deliveries that came with no voucher.
    final list = (app.employee?.can('receive') ?? false) ? await db.openReceipts() : <ReceiptDoc>[];
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

  /// Scanning here opens the voucher that contains the item, straight on its quantity.
  Future<void> _onScan(String code) async {
    final app = AppScope.read(context);
    final h = await findScanned(context, app, code);
    if (h == null || !mounted) return;
    final p = h.product;
    final having = (items ?? []).where((r) => r.lines.any((l) => l.productId == p.id)).toList();
    if (having.length == 1) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReceiveScreen(receiptId: having.first.id, openProductId: p.id),
        ),
      );
      _load();
    } else if (having.isEmpty) {
      beepError();
      toast(context, '${p.name} مش موجود في أي سند مفتوح');
    } else {
      toast(context, '${p.name} موجود في ${having.length} سندات. افتح السند الصح الأول');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    var list = (items ?? []).where((r) => query.isEmpty || '${r.id}'.contains(query) || r.supplier.contains(query)).toList();
    final canNew = app.employee?.can('new_receipt') ?? false;
    list.sort((a, b) => newestFirst ? b.createdAt.compareTo(a.createdAt) : a.createdAt.compareTo(b.createdAt));
    return WorkScaffold(
      title: 'استلام',
      onScan: _onScan,
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items!.isEmpty
          ? Center(
              child: StateMessage(
                icon: Icons.inbox_outlined,
                title: 'مفيش سندات مستنية الاستلام',
                sub: 'المشرف بيضيف السندات من لوحة التحكم. بعدها اعمل ${W.sync}.',
                action: Column(
                  children: [
                    if (canNew) ...[
                      BigButton(
                        'استلام من غير سند',
                        icon: Icons.add,
                        onPressed: () async {
                          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewReceiptScreen()));
                          _load();
                        },
                      ),
                      const SizedBox(height: S.s),
                    ],
                    BigButton.light(W.syncNow, icon: Icons.sync, onPressed: () => app.sync(full: true)),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(S.edge),
              children: [
                if (canNew) ...[
                  BigButton.light(
                    'استلام من غير سند',
                    icon: Icons.add,
                    onPressed: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewReceiptScreen()));
                      _load();
                    },
                  ),
                  const SizedBox(height: S.s),
                ],
                Text('${items!.length} سند مستني · امسح صنف لفتح السند بتاعه', style: T.sub),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryScreen(kind: 'receipts'))),
                      icon: const Icon(Icons.history, size: 20),
                      label: const Text('السندات المستلمة', style: T.label),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() => newestFirst = !newestFirst),
                      icon: const Icon(Icons.swap_vert, size: 20),
                      label: Text(newestFirst ? 'الأحدث' : 'الأقدم', style: T.label),
                    ),
                  ],
                ),
                if (items!.length > 5)
                  Padding(
                    padding: const EdgeInsets.only(bottom: S.s),
                    child: TextField(
                      onChanged: (v) => setState(() => query = v.trim()),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => hideKeyboard(),
                      onTapOutside: (_) => hideKeyboard(),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'رقم السند أو اسم المورد',
                        filled: true,
                        fillColor: cSurface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(S.radius),
                          borderSide: const BorderSide(color: cLine),
                        ),
                      ),
                    ),
                  ),
                for (final r in list)
                  ItemRow(
                    title: r.supplier,
                    amount: '#${r.id}',
                    details: Text('${r.lines.length} أصناف · ${_date(r.createdAt)}'),
                    controls: (progress[r.id] ?? 0) > 0
                        ? Pill('اتراجع ${progress[r.id]} من ${r.lines.length}', fg: cOrange, bg: cOrange2, icon: Icons.timelapse)
                        : const Pill('لم يبدأ', icon: Icons.radio_button_unchecked),
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReceiveScreen(receiptId: r.id)));
                      _load();
                    },
                  ),
              ],
            ),
    );
  }
}

class _Recv {
  int qty;
  String mode;
  _Recv(this.qty, this.mode);
}

enum _Filter { all, pending, diff, ok }

class ReceiveScreen extends StatefulWidget {
  final int receiptId;

  /// When opened by scanning from the list: ask this item's quantity right away.
  final int? openProductId;
  const ReceiveScreen({super.key, required this.receiptId, this.openProductId});
  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  ReceiptDoc? r;
  final products = <int, Product>{};
  final recv = <int, _Recv>{};
  final extra = <int>[];
  final notes = <String>[];
  final lineNotes = <int, String>{}; // per item, e.g. "3 علب تالفة"
  String freeNote = '';
  int? lastId;
  _Filter filter = _Filter.all;
  late final _noteCtl = TextEditingController();

  String get _key => 'draft_receipt_${widget.receiptId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _noteCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = AppScope.read(context).db;
    final doc = await db.receiptById(widget.receiptId);
    final d = await db.getJson(_key);
    if (d is Map) {
      (d['recv'] as Map).forEach((k, v) => recv[int.parse(k as String)] = _Recv(v['q'] as int, v['m'] as String));
      extra.addAll((d['extra'] as List).cast<int>());
      notes.addAll((d['notes'] as List).cast<String>());
      freeNote = (d['free'] as String?) ?? '';
      ((d['ln'] as Map?) ?? const {}).forEach((k, v) => lineNotes[int.parse(k as String)] = v as String);
      _noteCtl.text = freeNote;
    }
    if (doc != null) products.addAll(await db.productsByIds([...doc.lines.map((l) => l.productId), ...extra]));
    if (mounted) setState(() => r = doc);
    final open = widget.openProductId;
    if (open != null && doc != null && mounted && products.containsKey(open)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _qty(open);
      });
    }
  }

  Future<void> _save() => AppScope.read(context).db.setJson(_key, {
    'recv': {
      for (final e in recv.entries) '${e.key}': {'q': e.value.qty, 'm': e.value.mode},
    },
    'extra': extra,
    'notes': notes,
    'free': freeNote,
    'ln': {for (final e in lineNotes.entries) '${e.key}': e.value},
  });

  ReceiptLine? _line(int pid) {
    for (final l in r!.lines) {
      if (l.productId == pid) return l;
    }
    return null;
  }

  int? _diff(int pid) {
    final x = recv[pid];
    if (x == null) return null;
    final p = products[pid]!;
    final l = _line(pid);
    return p.toBase(x.qty, x.mode) - (l == null ? 0 : p.toBase(l.ordered, l.mode));
  }

  /// (text, icon, fg, bg) or null when not reviewed yet. Always words, not colour only.
  (String, IconData, Color, Color)? _status(int pid) {
    final d = _diff(pid);
    if (d == null) return null;
    if (_line(pid) == null) return ('زائد غير مطلوب', Icons.add_circle_outline, cBlue, cBlue2);
    final p = products[pid]!;
    if (d == 0) return ('مطابق', Icons.check_circle_outline, cGreen, cGreen2);
    return d < 0
        ? ('ناقص ${_amount(p, -d)}', Icons.remove_circle_outline, cOrange, cOrange2)
        : ('زيادة ${_amount(p, d)}', Icons.add_circle_outline, cBlue, cBlue2);
  }

  String _amount(Product p, int base) {
    if (p.isKg) return '${money(base)} كجم';
    if (p.carton > 0 && base % (p.carton * 1000) == 0) return '${base ~/ (p.carton * 1000)} كرتون';
    return '${qty(base, 'piece')} ${p.pieceName}';
  }

  Future<void> _qty(int pid, {bool isExtra = false, String? scannedMode}) async {
    final p = products[pid]!;
    final l = _line(pid);
    final cur = recv[pid];
    final res = await numberPad(
      context,
      title: p.name,
      pieceName: p.pieceName,
      hint: l != null
          ? 'المطلوب: ${p.qtyOf(l.ordered, l.mode)} — اكتب اللي وصل فعلاً (صفر لو ماوصلش)'
          : 'صنف مش في السند — اكتب الكمية اللي وصلت',
      modes: p.modes,
      // Only a carton barcode changes the unit; the item's normal barcode keeps the ordered unit.
      mode: cur?.mode ?? (scannedMode == 'carton' && p.carton > 0 ? 'carton' : null) ?? l?.mode ?? p.modes.first,
      initial: cur?.qty,
      allowZero: l != null,
      carton: p.carton,
      preview: l == null
          ? null
          : (q, m) {
              final d = p.toBase(q, m) - p.toBase(l.ordered, l.mode);
              return d == 0 ? 'مطابق للمطلوب' : (d < 0 ? 'ناقص ${_amount(p, -d)}' : 'زيادة ${_amount(p, d)}');
            },
    );
    if (res?.scanned != null) return _onScan(res!.scanned!);
    if (res == null || !mounted) return;
    setState(() {
      if (isExtra && !extra.contains(pid)) extra.add(pid);
      recv[pid] = _Recv(res.qty, res.mode);
      lastId = pid;
    });
    _save();
  }

  void _full(ReceiptLine l) {
    beepOk();
    setState(() {
      recv[l.productId] = _Recv(l.ordered, l.mode);
      lastId = l.productId;
    });
    _save();
  }

  Future<void> _onProduct(ScanHit? h) async {
    if (h == null || !mounted) return;
    final p = h.product;
    products[p.id] = p;
    if (_line(p.id) != null || extra.contains(p.id)) return _qty(p.id, scannedMode: h.mode);
    beepError();
    final ok = await confirmSheet(
      context,
      title: 'الصنف ده مش في السند',
      body: Text('${p.name}\nمش مطلوب من المورد في السند ده. تضيفه كصنف زائد؟'),
      yes: 'أضفه كصنف زائد',
      no: 'إلغاء',
      danger: true,
    );
    if (ok) await _qty(p.id, isExtra: true, scannedMode: h.mode);
  }

  Future<void> _onScan(String code) async {
    final app = AppScope.read(context);
    final h = await app.db.lookup(code);
    if (h == null) {
      if (mounted) await _onProduct(await findScanned(context, app, code));
      return;
    }
    if (_line(h.product.id) != null || extra.contains(h.product.id)) beepOk();
    await _onProduct(h);
  }

  Future<void> _finish() async {
    final left = r!.lines.where((l) => !recv.containsKey(l.productId)).toList();
    if (left.isNotEmpty) {
      beepError();
      await alertSheet(
        context,
        title: 'باقي ${left.length} أصناف ماتراجعتش',
        body: Text(
          '${left.map((l) => '• ${products[l.productId]?.name ?? ''}').join('\n')}\n\nلكل صنف: «كامل» لو وصل زي المطلوب، أو اضغط عليه واكتب اللي وصل.',
        ),
      );
      setState(() => filter = _Filter.pending);
      return;
    }
    final all = [...r!.lines.map((l) => l.productId), ...extra];
    final diffs = all.where((pid) => _status(pid)!.$3 != cGreen).toList();
    final ok = await confirmSheet(
      context,
      title: 'تأكيد الاستلام؟',
      body: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .4),
        child: SingleChildScrollView(
          child: Text(
            diffs.isEmpty
                ? 'كل الأصناف (${all.length}) مطابقة للمطلوب.'
                : 'فيه فروقات في ${diffs.length} من ${all.length} صنف:\n${diffs.map((pid) => '• ${products[pid]!.name}: ${_status(pid)!.$1}').join('\n')}',
          ),
        ),
      ),
      yes: 'نعم، تأكيد',
    );
    if (!ok || !mounted) return;
    final app = AppScope.read(context);
    final allNotes = [...notes, if (freeNote.trim().isNotEmpty) freeNote.trim()];
    await app.db.enqueue('receipts', '${r!.id}', {
      'receipt_id': r!.id,
      'employee_id': app.employee?.id,
      'received_at': DateTime.now().toUtc().toIso8601String(),
      'notes': allNotes.join('، '),
      'lines': [
        for (final e in recv.entries)
          {'product_id': e.key, 'mode': e.value.mode, 'qty': money(e.value.qty), if (lineNotes[e.key] != null) 'note': lineNotes[e.key]},
      ],
    });
    for (final e in recv.entries) {
      await app.db.adjustStock(e.key, products[e.key]!.toBase(e.value.qty, e.value.mode));
    }
    await app.db.addHistory('receipts', '${r!.id}', {
      'supplier': r!.supplier,
      'employee': app.employee?.name,
      'diffs': diffs.length,
      'notes': allNotes.join('، '),
      'lines': [
        for (final pid in all)
          {
            'name': products[pid]!.name,
            'ordered': _line(pid) == null ? null : products[pid]!.qtyOf(_line(pid)!.ordered, _line(pid)!.mode),
            'received': products[pid]!.qtyOf(recv[pid]!.qty, recv[pid]!.mode),
            'status': _status(pid)!.$1,
            'note': lineNotes[pid],
          },
      ],
    });
    await app.db.markReceiptSent(r!.id);
    await app.db.set(_key, null);
    await app.recordSaved();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => _ReceiveDone(id: r!.id, supplier: r!.supplier, diffs: diffs.length),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final doc = r;
    if (doc == null) {
      return const WorkScaffold(
        title: 'سند',
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final reviewed = doc.lines.where((l) => recv.containsKey(l.productId)).length;
    final all = [...doc.lines.map((l) => l.productId), ...extra];
    final shown = all.where((pid) {
      final s = _status(pid);
      return switch (filter) {
        _Filter.all => true,
        _Filter.pending => s == null,
        _Filter.diff => s != null && s.$3 != cGreen,
        _Filter.ok => s != null && s.$3 == cGreen,
      };
    }).toList();
    final counts = {
      _Filter.all: all.length,
      _Filter.pending: all.where((p) => _status(p) == null).length,
      _Filter.diff: all.where((p) => _status(p) != null && _status(p)!.$3 != cGreen).length,
      _Filter.ok: all.where((p) => _status(p)?.$3 == cGreen).length,
    };
    return WorkScaffold(
      title: 'سند ${doc.id}',
      onScan: _onScan,
      body: Column(
        children: [
          // Pinned summary.
          Container(
            color: cSurface,
            padding: const EdgeInsets.fromLTRB(S.edge, S.s, S.edge, S.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(doc.supplier, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.item),
                    ),
                    Text('اتراجع $reviewed من ${doc.lines.length}', style: T.subStrong),
                  ],
                ),
                const SizedBox(height: S.xs),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: doc.lines.isEmpty ? 0 : reviewed / doc.lines.length,
                    minHeight: 6,
                    backgroundColor: cGray2,
                    color: cPrimary,
                  ),
                ),
                if (doc.note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: S.xs),
                    child: Text('ملاحظة المشرف: ${doc.note}', style: T.sub),
                  ),
                const SizedBox(height: S.s),
                Wrap(
                  spacing: S.xs,
                  runSpacing: S.xs,
                  children: [
                    for (final f in _Filter.values)
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          '${switch (f) {
                            _Filter.all => 'الكل',
                            _Filter.pending => 'لم يُراجع',
                            _Filter.diff => 'فيه فرق',
                            _Filter.ok => 'مطابق',
                          }} (${counts[f]})',
                        ),
                        selected: filter == f,
                        onSelected: (_) => setState(() => filter = f),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(S.edge),
              children: [
                ScanBar(
                  text: 'امسح الصنف لتسجيل كميته',
                  onType: () async => _onProduct(await typeAndFind(context, app)),
                  onSearch: () async => _onProduct(await searchAndPick(context, app)),
                ),
                if (shown.isEmpty) const StateMessage(icon: Icons.filter_alt_off_outlined, title: 'مفيش أصناف في الفلتر ده'),
                for (final pid in shown) _row(pid),
                const SizedBox(height: S.m),
                const Text('ملاحظات الاستلام (اختياري)', style: T.label),
                const SizedBox(height: S.xs),
                Wrap(
                  spacing: S.xs,
                  runSpacing: S.xs,
                  children: [
                    for (final n in noteChips)
                      FilterChip(
                        label: Text(n),
                        selected: notes.contains(n),
                        selectedColor: cOrange2,
                        onSelected: (on) {
                          setState(() => on ? notes.add(n) : notes.remove(n));
                          _save();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: S.s),
                TextField(
                  controller: _noteCtl,
                  maxLines: 2,
                  onChanged: (v) {
                    freeNote = v;
                    _save();
                  },
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => hideKeyboard(),
                  onTapOutside: (_) => hideKeyboard(),
                  decoration: InputDecoration(
                    hintText: 'ملاحظة تانية، مثال: 3 علب زيت تالفة',
                    filled: true,
                    fillColor: cSurface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(S.radius),
                      borderSide: const BorderSide(color: cLine),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      footer: Footer(
        children: [BigButton('تأكيد الاستلام', icon: Icons.check, onPressed: _finish)],
      ),
    );
  }

  Widget _row(int pid) {
    final p = products[pid];
    if (p == null) {
      return const CardBox(
        child: Text('صنف مش موجود على الجهاز. اعمل مزامنة.', style: TextStyle(color: cRed)),
      );
    }
    final l = _line(pid);
    final x = recv[pid];
    final s = _status(pid);
    return ItemRow(
      key: ValueKey(pid),
      title: p.name,
      highlight: pid == lastId,
      accent: s?.$3,
      badge: s == null ? const Pill('لم يُراجع', icon: Icons.radio_button_unchecked) : Pill(s.$1, fg: s.$3, bg: s.$4, icon: s.$2),
      onTap: () => _qty(pid),
      details: Text.rich(
        TextSpan(
          children: [
            if (l != null) ...[const TextSpan(text: 'مطلوب '), TextSpan(text: p.qtyOf(l.ordered, l.mode), style: T.subStrong)],
            if (x != null) ...[
              TextSpan(text: l != null ? ' · مستلم ' : 'مستلم '),
              TextSpan(text: p.qtyOf(x.qty, x.mode), style: T.subStrong),
            ],
            if (lineNotes[pid] != null)
              TextSpan(
                text: '\nملاحظة: ${lineNotes[pid]}',
                style: const TextStyle(color: cOrange, fontWeight: FontWeight.w700),
              ),
          ],
        ),
      ),
      controls: x == null && l != null
          ? SizedBox(
              height: S.touch,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: cPrimary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => _full(l),
                icon: const Icon(Icons.check, size: 20),
                label: const Text('كامل', style: T.button),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconBox(
                  lineNotes[pid] == null ? Icons.note_add_outlined : Icons.sticky_note_2,
                  label: 'ملاحظة على الصنف',
                  fg: lineNotes[pid] == null ? cInk : cOrange,
                  bg: lineNotes[pid] == null ? cGray2 : cOrange2,
                  onPressed: () => _lineNote(pid),
                ),
                const SizedBox(width: S.xs),
                IconBox(Icons.edit_outlined, label: 'تعديل الكمية', onPressed: () => _qty(pid)),
              ],
            ),
    );
  }

  /// Note for one item: quick choices plus free text.
  Future<void> _lineNote(int pid) async {
    final r = await showAppSheet<String>(context, _NoteSheet(name: products[pid]!.name, initial: lineNotes[pid] ?? ''));
    if (r == null || !mounted) return;
    setState(() => r.isEmpty ? lineNotes.remove(pid) : lineNotes[pid] = r);
    _save();
  }
}

class _ReceiveDone extends StatelessWidget {
  final int id, diffs;
  final String supplier;
  const _ReceiveDone({required this.id, required this.supplier, required this.diffs});
  @override
  Widget build(BuildContext context) => WorkScaffold(
    title: 'استلام',
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
        Text('تم تأكيد استلام السند $id', textAlign: TextAlign.center, style: T.heading),
        Text('$supplier · ${diffs == 0 ? 'كله مطابق' : 'فيه فروقات في $diffs صنف'}', textAlign: TextAlign.center, style: T.sub),
        const SizedBox(height: S.m),
        Center(child: SendStatus(outboxKey: 'receipts:$id')),
        const SizedBox(height: S.l),
        BigButton.light('رجوع للسندات', onPressed: () => Navigator.of(context).pop()),
      ],
    ),
  );
}

/// Owns its text controller, so it is disposed only after the sheet has closed.
class _NoteSheet extends StatefulWidget {
  final String name, initial;
  const _NoteSheet({required this.name, required this.initial});
  @override
  State<_NoteSheet> createState() => _NoteSheetState();
}

class _NoteSheetState extends State<_NoteSheet> {
  late final ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('ملاحظة على: ${widget.name}', style: T.heading),
      const SizedBox(height: S.s),
      Wrap(
        spacing: S.xs,
        runSpacing: S.xs,
        children: [
          for (final n in noteChips)
            ActionChip(label: Text(n), onPressed: () => ctl.text = ctl.text.trim().isEmpty ? n : '${ctl.text.trim()}، $n'),
        ],
      ),
      const SizedBox(height: S.s),
      TextField(
        controller: ctl,
        autofocus: true,
        maxLength: 200,
        decoration: InputDecoration(
          hintText: 'مثال: 3 علب تالفة',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(S.radius)),
        ),
      ),
      Row(
        children: [
          Expanded(child: BigButton.light('مسح الملاحظة', onPressed: () => Navigator.pop(context, ''))),
          const SizedBox(width: S.s),
          Expanded(child: BigButton('حفظ', onPressed: () => Navigator.pop(context, ctl.text.trim()))),
        ],
      ),
    ],
  );
}
