import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/feedback.dart';
import '../util/format.dart';
import '../util/ids.dart';
import 'history_screen.dart';
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
  // The ministry ration invoice this sale delivers: asked before the first item.
  String? ministryNo;
  int? ministryTotal; // fils, optional
  String? lastKey; // last scanned line, highlighted until the next one
  String? lastAdded; // "+1 حبة" next to it
  String filter = '';
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
      ministryNo = draft['mi'] as String?;
      ministryTotal = draft['mt'] as int?;
    }
    products.addAll(await db.productsByIds(lines.map((l) => l.productId)));
    lines.removeWhere((l) => !products.containsKey(l.productId));
    if (mounted) setState(() => loaded = true);
    if (ministryNo == null && mounted) await _askMinistry();
  }

  Future<void> _save() => AppScope.read(context).db.setJson(
    'draft_sale',
    lines.isEmpty && ministryNo == null ? null : {'lines': lines.map((l) => l.toJson()).toList(), 'mi': ministryNo, 'mt': ministryTotal},
  );

  /// Ministry invoice number (required) and its total; refused if this device already sold that invoice.
  Future<bool> _askMinistry() async {
    final r = await showAppSheet<(String, int?)>(context, _MinistrySheet(no: ministryNo ?? '', total: ministryTotal));
    if (r == null || !mounted) return ministryNo != null;
    final app = AppScope.read(context);
    final old = r.$1 == ministryNo ? null : await app.db.saleForMinistryInvoice(r.$1);
    if (!mounted) return false;
    if (old != null) {
      beepError();
      await confirmSheet(
        context,
        title: 'فاتورة الوزارة دي اتصرفت قبل كده',
        body: Text(
          'فاتورة الوزارة ${r.$1} اتباعت على الجهاز ده في ${saleNo(old)} '
          '(${old.at.toLocal().toString().substring(0, 16)}، ${money((old.data['total'] as num).toInt())} ${W.currency}).\n'
          'مينفعش تتصرف مرتين. لو فيه غلط، كلّم المدير.',
        ),
        yes: 'حسناً',
      );
      return ministryNo != null;
    }
    setState(() {
      ministryNo = r.$1;
      ministryTotal = r.$2;
    });
    await _save();
    return true;
  }

  int _lineTotal(SaleLine l) => lineTotal(products[l.productId]!.unitPrice(l.mode), l.qty);
  int get total => lines.fold(0, (a, l) => a + _lineTotal(l));
  String _key(SaleLine l) => l.id;

  /// Units for the summary: pieces (cartons counted as their pieces) and kilograms.
  String get unitsSummary {
    var pieces = 0, grams = 0;
    final names = <String>{};
    for (final l in lines) {
      final p = products[l.productId]!;
      if (l.mode == 'kg') {
        grams += l.qty;
      } else {
        pieces += p.toBase(l.qty, l.mode) ~/ 1000;
        names.add(p.pieceName);
      }
    }
    // One name when every item uses it (علبة), otherwise the neutral وحدة.
    final name = names.length == 1 ? names.first : 'وحدة';
    return [if (pieces > 0) '$pieces $name', if (grams > 0) '${money(grams)} كجم'].join(' + ');
  }

  /// Adds to the sale. Same product in the same unit: added to that line straight away
  /// (fast for repeated scans), with a "separate line" option. Same product in another
  /// unit: asks whether to add it to the existing line or keep it as a new line.
  Future<void> _add(Product p, String mode, int qty) async {
    products[p.id] = p;
    SaleLine? same;
    SaleLine? other;
    for (final l in lines.reversed) {
      if (l.productId != p.id) continue;
      if (l.mode == mode) {
        same ??= l;
      } else {
        other ??= l;
      }
    }
    if (same != null) {
      final line = same;
      _bring(line..qty += qty, '+${p.qtyOf(qty, mode)}');
      toast(
        context,
        'اتزوّد على البند: ${p.qtyOf(line.qty, mode)}',
        undoLabel: 'بند منفصل',
        undo: () {
          if (!mounted || !lines.contains(line)) return;
          line.qty -= qty;
          if (line.qty <= 0) lines.remove(line);
          _bring(SaleLine(p.id, mode, qty), '+${p.qtyOf(qty, mode)}');
        },
      );
      return;
    }
    if (other != null) {
      final existing = other;
      final choice = await showAppSheet<String>(
        context,
        Builder(
          builder: (ctx) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(p.name, style: T.heading),
              const SizedBox(height: S.xs),
              Text('موجود في الفاتورة: ${p.qtyOf(existing.qty, existing.mode)}\nالمسح ده: ${p.qtyOf(qty, mode)}', style: T.label),
              const SizedBox(height: S.m),
              BigButton('زوّد على البند القديم', icon: Icons.add, onPressed: () => Navigator.pop(ctx, 'merge')),
              const SizedBox(height: S.s),
              BigButton.light('اعمله بند جديد', icon: Icons.playlist_add, onPressed: () => Navigator.pop(ctx, 'new')),
            ],
          ),
        ),
      );
      if (!mounted || choice == null) return;
      if (choice == 'merge') {
        // Different units go together as pieces: 1 carton + 2 pieces = 8 pieces.
        final pieces = p.toBase(existing.qty, existing.mode) + p.toBase(qty, mode);
        existing
          ..mode = 'piece'
          ..qty = pieces;
        _bring(existing, '+${p.qtyOf(qty, mode)}');
        return;
      }
    }
    _bring(SaleLine(p.id, mode, qty), '+${p.qtyOf(qty, mode)}');
  }

  /// Puts [line] at the top of the list and highlights it.
  void _bring(SaleLine line, String note) {
    setState(() {
      lines.remove(line);
      lines.add(line);
      lastKey = _key(line);
      lastAdded = note;
      filter = '';
    });
    _save();
    if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  Future<void> _onProduct(ScanHit? h) async {
    if (h == null || !mounted) return;
    if (ministryNo == null && !await _askMinistry()) return;
    if (!mounted) return;
    final p = h.product;
    if (p.isKg) {
      final r = await numberPad(
        context,
        title: p.name,
        pieceName: p.pieceName,
        hint: '${money(p.price)} ${W.currency} / كجم — اكتب الوزن من الميزان',
        modes: const ['kg'],
        preview: (q, m) => 'الإجمالي: ${money(lineTotal(p.price, q))} ${W.currency}',
        ok: 'إضافة',
      );
      if (r?.scanned != null) return _onScan(r!.scanned!);
      if (r != null) await _add(p, 'kg', r.qty);
    } else {
      // A carton barcode adds one carton; the piece barcode one piece.
      await _add(p, h.mode == 'carton' && p.carton > 0 ? 'carton' : 'piece', 1000);
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
      pieceName: p.pieceName,
      hint: l.mode == 'kg' ? 'اكتب الوزن من الميزان' : 'اكتب الكمية',
      modes: p.modes,
      mode: l.mode,
      initial: l.qty,
      carton: p.carton,
      preview: (q, m) => '${money(p.unitPrice(m))} × ${p.qtyOf(q, m)} = ${money(lineTotal(p.unitPrice(m), q))} ${W.currency}',
    );
    if (r?.scanned != null) return _onScan(r!.scanned!);
    if (r == null) return;
    setState(() {
      l
        ..qty = r.qty
        ..mode = r.mode;
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

  /// Tapping a row: full details, purchase price, change quantity or unit, delete.
  Future<void> _details(SaleLine l) async {
    final p = products[l.productId]!;
    final seeCost = AppScope.read(context).employee?.can('see_cost') ?? false;
    final action = await showAppSheet<String>(
      context,
      Builder(
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: T.heading),
            const SizedBox(height: S.s),
            seeCost
                ? _kv('بيع / شراء', '${money(p.unitPrice(l.mode))} / ${money(p.unitCost(l.mode))} ${W.currency} لل${p.unitName(l.mode)}')
                : _kv('السعر', '${money(p.unitPrice(l.mode))} ${W.currency} لل${p.unitName(l.mode)}'),
            _kv('الكمية', p.qtyOf(l.qty, l.mode) + (l.mode == 'carton' ? ' = ${qty(l.qty * p.carton, 'piece')} ${p.pieceName}' : '')),
            _kv('إجمالي السطر', '${money(_lineTotal(l))} ${W.currency}'),
            const SizedBox(height: S.m),
            Row(
              children: [
                Expanded(
                  child: BigButton.light('تعديل الكمية', icon: Icons.edit_outlined, onPressed: () => Navigator.pop(ctx, 'edit')),
                ),
                const SizedBox(width: S.s),
                Expanded(
                  child: BigButton.danger('حذف', icon: Icons.delete_outline, onPressed: () => Navigator.pop(ctx, 'delete')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (action == 'edit') await _editQty(l);
    if (action == 'delete') _delete(l);
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Text(k, style: T.sub),
        const SizedBox(width: S.s),
        Expanded(
          child: Text(v, textAlign: TextAlign.left, style: T.subStrong),
        ),
      ],
    ),
  );

  Future<void> _clear() async {
    final ok = await confirmSheet(
      context,
      title: 'إلغاء الفاتورة كلها؟',
      body: Text('هيتمسح ${lines.length} صنف من الفاتورة. مفيش بيع هيتسجل.'),
      yes: 'نعم، إلغاء الفاتورة',
      no: 'رجوع للفاتورة',
      danger: true,
    );
    if (!ok) return;
    setState(() => lines.clear());
    _save();
  }

  Future<void> _finish() async {
    if (ministryNo == null && !await _askMinistry()) return;
    if (!mounted) return;
    final t = total;
    final n = lines.length;
    final mismatch = ministryTotal != null && ministryTotal != t;
    final ok = await confirmSheet(
      context,
      title: 'تسجيل البيع',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('فاتورة الوزارة $ministryNo', style: T.subStrong),
          if (mismatch)
            Text(
              'إجمالي فاتورة الوزارة ${money(ministryTotal!)} والفاتورة هنا ${money(t)}: فرق ${money((t - ministryTotal!).abs())} ${W.currency}. راجع الأصناف والكميات.',
              style: T.label.copyWith(color: cRed),
            ),
          Text('$n صنف · $unitsSummary', style: T.sub),
          Text('${money(t)} ${W.currency}', style: T.total.copyWith(fontSize: 32)),
          const SizedBox(height: S.xs),
          const Text('الضغط على «تم الدفع» بيسجّل البيع وبينقّص المخزون.', style: T.sub),
        ],
      ),
      yes: 'تم الدفع',
    );
    if (!ok || !mounted) return;
    final app = AppScope.read(context);
    final id = uuid4();
    final no = await app.db.nextSerial('sales');
    await app.db.enqueue('sales', id, {
      'id': id,
      'device_no': no,
      'ministry_invoice_no': ministryNo,
      if (ministryTotal != null) 'ministry_total': money(ministryTotal!),
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
    await app.db.addHistory('sales', id, {
      'no': no,
      'mi': ministryNo,
      'mt': ministryTotal,
      'total': t,
      'employee': app.employee?.name,
      'lines': [
        for (final l in lines)
          {
            'name': products[l.productId]!.name,
            'mode': l.mode,
            'pn': products[l.productId]!.pieceName,
            'qty': l.qty,
            'price': products[l.productId]!.unitPrice(l.mode),
            'total': _lineTotal(l),
          },
      ],
    });
    final mi = ministryNo;
    lines.clear();
    ministryNo = null;
    ministryTotal = null;
    await _save();
    await app.recordSaved();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => SaleDoneScreen(total: t, items: n, id: id, no: no, ministryNo: mi),
      ),
    );
  }

  Widget _ministryRow() {
    final diff = ministryTotal == null || lines.isEmpty ? null : total - ministryTotal!;
    return Padding(
      padding: const EdgeInsets.only(bottom: S.xs),
      child: Material(
        color: ministryNo == null ? cOrange2 : (diff != null && diff != 0 ? cRed2 : cBlue2),
        borderRadius: BorderRadius.circular(S.radius),
        child: InkWell(
          key: const Key('ministry'),
          borderRadius: BorderRadius.circular(S.radius),
          onTap: _askMinistry,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.m, vertical: S.xs),
            child: Row(
              children: [
                Icon(Icons.receipt_outlined, size: 20, color: ministryNo == null ? cOrange : cBlue),
                const SizedBox(width: S.s),
                Expanded(
                  child: Text(
                    ministryNo == null
                        ? 'اكتب رقم فاتورة الوزارة'
                        : 'فاتورة الوزارة $ministryNo'
                              '${ministryTotal != null ? ' · ${money(ministryTotal!)}' : ''}'
                              '${diff != null && diff != 0 ? ' · فرق ${money(diff.abs())}' : ''}',
                    style: T.label.copyWith(color: diff != null && diff != 0 ? cRed : (ministryNo == null ? cOrange : cBlue)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Text('تغيير', style: T.label),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    Future<void> type() async => _onProduct(await typeAndFind(context, app));
    Future<void> search() async => _onProduct(await searchAndPick(context, app));
    final shown = lines.reversed.where((l) => filter.isEmpty || products[l.productId]!.name.contains(filter)).toList();
    return WorkScaffold(
      title: 'بيع',
      onScan: _onScan,
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(S.edge),
              children: [
                _ministryRow(),
                if (lines.isEmpty)
                  ScanPrompt(title: 'امسح أول صنف لبدء البيع', sub: 'كل مسح بيضيف حبة واحدة', onType: type, onSearch: search)
                else
                  ScanBar(text: 'امسح الصنف التالي', onType: type, onSearch: search),
                if (lines.length >= 8)
                  Padding(
                    padding: const EdgeInsets.only(bottom: S.s),
                    child: TextField(
                      onChanged: (v) => setState(() => filter = v.trim()),
                      onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'دوّر في الفاتورة',
                        filled: true,
                        fillColor: cSurface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(S.radius),
                          borderSide: const BorderSide(color: cLine),
                        ),
                      ),
                    ),
                  ),
                for (final l in shown) _row(l),
                if (lines.isNotEmpty) ...[
                  const SizedBox(height: S.l),
                  Center(
                    child: TextButton.icon(
                      onPressed: _clear,
                      icon: const Icon(Icons.delete_sweep_outlined, color: cRed),
                      label: const Text(
                        'إلغاء الفاتورة كلها',
                        style: TextStyle(color: cRed, fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ],
            ),
      footer: Footer(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${lines.length} صنف', style: T.subStrong),
                    if (lines.isNotEmpty) Text(unitsSummary, style: T.sub),
                  ],
                ),
              ),
              Text(money(loaded ? total : 0), textDirection: TextDirection.ltr, style: T.total),
              const Text(' ${W.currency}', style: T.label),
            ],
          ),
          const SizedBox(height: S.s),
          BigButton('إنهاء البيع', icon: Icons.check, onPressed: lines.isEmpty ? null : _finish),
        ],
      ),
    );
  }

  Widget _row(SaleLine l) {
    final p = products[l.productId]!;
    final up = p.unitPrice(l.mode);
    final kg = l.mode == 'kg';
    final isLast = _key(l) == lastKey;
    return ItemRow(
      key: ValueKey(_key(l)),
      title: p.name,
      amount: money(_lineTotal(l)),
      highlight: isLast,
      onTap: () => _details(l),
      badge: isLast && lastAdded != null ? Pill(lastAdded!, fg: cGreen, bg: cSurface, icon: Icons.add) : null,
      details: Text(
        kg
            ? '${qty(l.qty, 'kg')} كجم × ${money(up)}'
            : '${money(up)} × ${p.qtyOf(l.qty, l.mode)}${l.mode == 'carton' ? ' (${qty(l.qty * p.carton, 'piece')} ${p.pieceName})' : ''}',
      ),
      controls: kg
          ? QtyStepper(text: p.qtyOf(l.qty, l.mode), onTapQty: () => _editQty(l))
          : QtyStepper(
              text: p.qtyOf(l.qty, l.mode),
              onTapQty: () => _editQty(l),
              onPlus: () {
                setState(() => l.qty += 1000);
                _save();
              },
              onMinus: l.qty <= 1000
                  ? null
                  : () {
                      setState(() => l.qty -= 1000);
                      _save();
                    },
            ),
    );
  }
}

class SaleDoneScreen extends StatelessWidget {
  final int total, items, no;
  final String id;
  final String? ministryNo;
  const SaleDoneScreen({super.key, required this.total, required this.items, required this.id, required this.no, this.ministryNo});

  @override
  Widget build(BuildContext context) => WorkScaffold(
    title: 'بيع',
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
        const Text('تم تسجيل البيع', textAlign: TextAlign.center, style: T.heading),
        Text('${money(total)} ${W.currency}', textAlign: TextAlign.center, style: T.total.copyWith(fontSize: 32)),
        Text('فاتورة رقم $no · $items صنف', textAlign: TextAlign.center, style: T.subStrong),
        if (ministryNo != null) Text('فاتورة الوزارة $ministryNo', textAlign: TextAlign.center, style: T.sub),
        const SizedBox(height: S.m),
        Center(child: SendStatus(outboxKey: 'sales:$id')),
        const SizedBox(height: S.l),
        BigButton(
          'فاتورة جديدة',
          icon: Icons.shopping_cart_outlined,
          onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const SaleScreen())),
        ),
        const SizedBox(height: S.s),
        Row(
          children: [
            Expanded(child: BigButton.light('الرئيسية', onPressed: () => Navigator.of(context).pop())),
            const SizedBox(width: S.s),
            Expanded(
              child: BigButton.light(
                'سجل الفواتير',
                icon: Icons.receipt_long_outlined,
                onPressed: () =>
                    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HistoryScreen(kind: 'sales'))),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _MinistrySheet extends StatefulWidget {
  final String no;
  final int? total;
  const _MinistrySheet({required this.no, this.total});
  @override
  State<_MinistrySheet> createState() => _MinistrySheetState();
}

class _MinistrySheetState extends State<_MinistrySheet> {
  late final noCtl = TextEditingController(text: widget.no);
  late final totalCtl = TextEditingController(text: widget.total == null ? '' : money(widget.total!));
  String? noError, totalError;

  @override
  void dispose() {
    noCtl.dispose();
    totalCtl.dispose();
    super.dispose();
  }

  void _ok() {
    final no = noCtl.text.replaceAll(RegExp(r'\s'), '');
    final raw = totalCtl.text.trim().replaceAll(',', '.');
    // Kuwaiti dinar: at most 3 decimals (fils), read exactly, never rounded.
    final fils = RegExp(r'^\d+(\.\d{1,3})?$').hasMatch(raw) ? parseMilli(raw) : null;
    setState(() {
      noError = !RegExp(r'^[0-9]{4,30}$').hasMatch(no) ? 'اكتب رقم فاتورة الوزارة (أرقام بس)' : null;
      totalError = raw.isNotEmpty && fils == null ? 'اكتب المبلغ بالدينار، 3 أرقام عشرية بالكتير (مثال 28.296)' : null;
    });
    if (noError != null || totalError != null) return;
    Navigator.pop(context, (no, raw.isEmpty ? null : fils));
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('فاتورة الوزارة', style: T.heading),
      const Text('اكتب «رقم الفاتورة» اللي في فاتورة صرف المواد المدعومة، والإجمالي علشان الجهاز يقارن.', style: T.sub),
      const SizedBox(height: S.s),
      TextField(
        key: const Key('ministry_no'),
        controller: noCtl,
        autofocus: true,
        keyboardType: TextInputType.number,
        maxLength: 30,
        style: T.heading,
        textDirection: TextDirection.ltr,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(labelText: 'رقم فاتورة الوزارة', errorText: noError, counterText: ''),
      ),
      TextField(
        key: const Key('ministry_total'),
        controller: totalCtl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _ok(),
        decoration: InputDecoration(labelText: 'إجمالي الفاتورة (${W.currency}) — اختياري', errorText: totalError),
      ),
      const SizedBox(height: S.s),
      BigButton('ابدأ البيع', icon: Icons.play_arrow, onPressed: _ok),
    ],
  );
}
