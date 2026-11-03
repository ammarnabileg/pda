import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/format.dart';
import '../util/ids.dart';
import 'history_screen.dart';
import 'receive_screen.dart' show noteChips;
import 'scan_helpers.dart';
import 'scope.dart';
import 'widgets.dart';

class _Line {
  final int productId;
  int qty;
  String mode;
  String? note;
  _Line(this.productId, this.qty, this.mode, [this.note]);
  Map<String, Object?> toJson() => {'p': productId, 'q': qty, 'm': mode, 'n': note};
}

/// A delivery that came without a voucher: pick the supplier, scan what arrived,
/// confirm. Stock goes up when it reaches the server, like any receipt.
class NewReceiptScreen extends StatefulWidget {
  const NewReceiptScreen({super.key});
  @override
  State<NewReceiptScreen> createState() => _NewReceiptScreenState();
}

class _NewReceiptScreenState extends State<NewReceiptScreen> {
  static const _draftKey = 'draft_new_receipt';
  String? id;
  int? supplierId;
  String supplierName = '';
  final lines = <_Line>[];
  final products = <int, Product>{};
  int? lastId;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppScope.read(context).db;
    final d = await db.getJson(_draftKey);
    if (d is Map) {
      id = d['id'] as String?;
      supplierId = d['sid'] as int?;
      supplierName = (d['sname'] as String?) ?? '';
      for (final j in (d['lines'] as List)) {
        lines.add(_Line(j['p'] as int, j['q'] as int, j['m'] as String, j['n'] as String?));
      }
      products.addAll(await db.productsByIds(lines.map((l) => l.productId)));
      lines.removeWhere((l) => !products.containsKey(l.productId));
    }
    if (mounted) setState(() => loaded = true);
    if (supplierName.isEmpty && mounted) WidgetsBinding.instance.addPostFrameCallback((_) => _pickSupplier());
  }

  Future<void> _save() {
    id ??= uuid4();
    return AppScope.read(context).db.setJson(_draftKey, {
      'id': id,
      'sid': supplierId,
      'sname': supplierName,
      'lines': [for (final l in lines) l.toJson()],
    });
  }

  Future<void> _pickSupplier() async {
    final list = await AppScope.read(context).db.suppliers();
    if (!mounted) return;
    final r = await showAppSheet<(int?, String)>(context, _SupplierSheet(suppliers: list));
    if (r == null || !mounted) {
      if (supplierName.isEmpty && lines.isEmpty && mounted) Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      supplierId = r.$1;
      supplierName = r.$2;
    });
    _save();
  }

  Future<void> _onProduct(ScanHit? h) async {
    if (h == null || !mounted) return;
    final p = h.product;
    products[p.id] = p;
    final existing = lines.where((l) => l.productId == p.id).firstOrNull;
    final r = await numberPad(
      context,
      title: p.name,
      hint: existing != null ? 'مستلم قبل كده: ${qtyText(existing.qty, existing.mode)} — الجديد هيتجمع عليه' : 'اكتب الكمية اللي وصلت',
      modes: p.modes,
      mode: h.mode == 'carton' && p.carton > 0 ? 'carton' : null,
      carton: p.carton,
      preview: (q, m) => m == 'carton' ? '= ${p.baseText(p.toBase(q, m))}' : null,
      ok: 'إضافة',
    );
    if (r?.scanned != null) return _onScan(r!.scanned!);
    if (r == null || !mounted) return;
    setState(() {
      if (existing == null) {
        lines.add(_Line(p.id, r.qty, r.mode));
      } else if (existing.mode == r.mode) {
        existing.qty += r.qty;
      } else {
        // Different units go together as pieces.
        existing
          ..qty = p.toBase(existing.qty, existing.mode) + p.toBase(r.qty, r.mode)
          ..mode = 'piece';
      }
      lastId = p.id;
    });
    _save();
  }

  Future<void> _onScan(String code) async => _onProduct(await findScanned(context, AppScope.read(context), code));

  Future<void> _actions(_Line l) async {
    final p = products[l.productId]!;
    final a = await showAppSheet<String>(
      context,
      Builder(
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: T.heading),
            Text('مستلم: ${qtyText(l.qty, l.mode)}', style: T.sub),
            const SizedBox(height: S.m),
            Row(
              children: [
                Expanded(
                  child: BigButton.light('تعديل الكمية', icon: Icons.edit_outlined, onPressed: () => Navigator.pop(ctx, 'edit')),
                ),
                const SizedBox(width: S.s),
                Expanded(
                  child: BigButton.light('ملاحظة', icon: Icons.note_add_outlined, onPressed: () => Navigator.pop(ctx, 'note')),
                ),
              ],
            ),
            const SizedBox(height: S.s),
            BigButton.danger('حذف', icon: Icons.delete_outline, onPressed: () => Navigator.pop(ctx, 'delete')),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (a == 'edit') {
      final r = await numberPad(context, title: p.name, modes: p.modes, mode: l.mode, initial: l.qty, carton: p.carton);
      if (r?.scanned != null) return _onScan(r!.scanned!);
      if (r != null) {
        setState(() {
          l
            ..qty = r.qty
            ..mode = r.mode;
        });
      }
    } else if (a == 'note') {
      final n = await showAppSheet<String>(context, _NoteSheet(initial: l.note ?? ''));
      if (n != null) setState(() => l.note = n.isEmpty ? null : n);
    } else if (a == 'delete') {
      final i = lines.indexOf(l);
      setState(() => lines.remove(l));
      toast(
        context,
        'تم حذف ${p.name}',
        undo: () {
          if (!mounted) return;
          setState(() => lines.insert(i.clamp(0, lines.length), l));
          _save();
        },
      );
    }
    _save();
  }

  Future<void> _finish() async {
    if (supplierName.isEmpty) return _pickSupplier();
    final ok = await confirmSheet(
      context,
      title: 'تأكيد الاستلام؟',
      body: Text('المورد: $supplierName\n${lines.length} صنف.\nالسند هيروح للمشرف يوافق عليه من لوحة التحكم، والرصيد هيزيد بعد موافقته.'),
      yes: 'نعم، تأكيد',
    );
    if (!ok || !mounted) return;
    final app = AppScope.read(context);
    await _save();
    final rid = id!;
    await app.db.enqueue('new_receipts', rid, {
      'id': rid,
      'supplier_id': supplierId,
      'supplier_name': supplierName,
      'employee_id': app.employee?.id,
      'received_at': DateTime.now().toUtc().toIso8601String(),
      'lines': [
        for (final l in lines) {'product_id': l.productId, 'mode': l.mode, 'qty': money(l.qty), if (l.note != null) 'note': l.note},
      ],
    });
    // No local stock change: the supervisor approves the voucher first.
    await app.db.addHistory('new_receipts', rid, {
      'supplier': supplierName,
      'employee': app.employee?.name,
      'diffs': 0,
      'lines': [
        for (final l in lines)
          {
            'product_id': l.productId,
            'name': products[l.productId]!.name,
            'received': qtyText(l.qty, l.mode),
            'status': 'مستني موافقة المشرف',
            'note': l.note,
          },
      ],
    });
    await app.db.set(_draftKey, null);
    await app.recordSaved();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => _Done(id: rid, supplier: supplierName, items: lines.length),
      ),
    );
  }

  Future<void> _discard() async {
    final ok = await confirmSheet(
      context,
      title: 'إلغاء السند ده؟',
      body: Text('هيتمسح ${lines.length} صنف. مفيش حاجة هتتسجل.'),
      yes: 'نعم، إلغاء',
      no: 'رجوع للسند',
      danger: true,
    );
    if (!ok || !mounted) return;
    await AppScope.read(context).db.set(_draftKey, null);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    Future<void> type() async => _onProduct(await typeAndFind(context, app));
    Future<void> search() async => _onProduct(await searchAndPick(context, app));
    return WorkScaffold(
      title: 'استلام من غير سند',
      onScan: _onScan,
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(S.edge),
              children: [
                ItemRow(
                  title: supplierName.isEmpty ? 'اختار المورد' : supplierName,
                  details: Text(supplierId == null && supplierName.isNotEmpty ? 'مورد جديد — هيتضاف للوحة التحكم' : 'المورد'),
                  controls: IconBox(Icons.edit_outlined, label: 'تغيير المورد', onPressed: _pickSupplier),
                  onTap: _pickSupplier,
                ),
                if (lines.isEmpty)
                  ScanPrompt(title: 'امسح أول صنف وصل', sub: 'بعد كل مسح اكتب الكمية اللي وصلت', onType: type, onSearch: search)
                else
                  ScanBar(text: 'امسح الصنف التالي', onType: type, onSearch: search),
                for (final l in lines.reversed)
                  ItemRow(
                    key: ValueKey(l.productId),
                    title: products[l.productId]!.name,
                    highlight: l.productId == lastId,
                    onTap: () => _actions(l),
                    details: Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'مستلم '),
                          TextSpan(text: qtyText(l.qty, l.mode), style: T.subStrong),
                          if (l.note != null)
                            TextSpan(
                              text: '\nملاحظة: ${l.note}',
                              style: const TextStyle(color: cOrange, fontWeight: FontWeight.w700),
                            ),
                        ],
                      ),
                    ),
                    controls: IconBox(Icons.more_horiz, label: 'خيارات', onPressed: () => _actions(l)),
                  ),
                if (lines.isNotEmpty || supplierName.isNotEmpty)
                  Center(
                    child: TextButton.icon(
                      onPressed: _discard,
                      icon: const Icon(Icons.delete_sweep_outlined, color: cRed),
                      label: const Text(
                        'إلغاء السند',
                        style: TextStyle(color: cRed, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
            ),
      footer: Footer(
        children: [
          BigButton(
            'تأكيد الاستلام (${lines.length} صنف)',
            icon: Icons.check,
            onPressed: lines.isEmpty || supplierName.isEmpty ? null : _finish,
          ),
        ],
      ),
    );
  }
}

class _SupplierSheet extends StatefulWidget {
  final List<(int, String)> suppliers;
  const _SupplierSheet({required this.suppliers});
  @override
  State<_SupplierSheet> createState() => _SupplierSheetState();
}

class _SupplierSheetState extends State<_SupplierSheet> {
  final ctl = TextEditingController();
  String q = '';

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.suppliers.where((s) => q.isEmpty || s.$2.contains(q)).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * .75,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('المورد', style: T.heading),
          const SizedBox(height: S.s),
          TextField(
            controller: ctl,
            onChanged: (v) => setState(() => q = v.trim()),
            decoration: InputDecoration(
              hintText: 'دوّر، أو اكتب اسم مورد جديد',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(S.radius)),
            ),
          ),
          const SizedBox(height: S.s),
          Expanded(
            child: ListView(
              children: [
                for (final s in shown)
                  ListTile(
                    title: Text(s.$2, style: T.item),
                    onTap: () => Navigator.pop(context, (s.$1, s.$2)),
                  ),
                if (q.isNotEmpty && !widget.suppliers.any((s) => s.$2 == q))
                  ListTile(
                    leading: const Icon(Icons.add_business_outlined, color: cPrimary),
                    title: Text('مورد جديد: $q', style: T.item.copyWith(color: cPrimary)),
                    subtitle: const Text('هيتضاف للوحة التحكم لما السند يوصل', style: T.sub),
                    onTap: () => Navigator.pop(context, (null, q)),
                  ),
                if (shown.isEmpty && q.isEmpty)
                  const StateMessage(
                    icon: Icons.storefront_outlined,
                    title: 'مفيش موردين على الجهاز',
                    sub: 'اكتب اسم المورد فوق، أو اعمل مزامنة',
                  ),
              ],
            ),
          ),
          BigButton.light('إلغاء', onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}

class _NoteSheet extends StatefulWidget {
  final String initial;
  const _NoteSheet({required this.initial});
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
      const Text('ملاحظة على الصنف', style: T.heading),
      const SizedBox(height: S.s),
      Wrap(
        spacing: S.xs,
        children: [
          for (final n in noteChips)
            ActionChip(label: Text(n), onPressed: () => ctl.text = ctl.text.trim().isEmpty ? n : '${ctl.text.trim()}، $n'),
        ],
      ),
      TextField(
        controller: ctl,
        autofocus: true,
        maxLength: 200,
        decoration: const InputDecoration(hintText: 'مثال: 3 علب تالفة'),
      ),
      Row(
        children: [
          Expanded(child: BigButton.light('مسح', onPressed: () => Navigator.pop(context, ''))),
          const SizedBox(width: S.s),
          Expanded(child: BigButton('حفظ', onPressed: () => Navigator.pop(context, ctl.text.trim()))),
        ],
      ),
    ],
  );
}

class _Done extends StatelessWidget {
  final String id, supplier;
  final int items;
  const _Done({required this.id, required this.supplier, required this.items});
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
        const Text('تم تسجيل الاستلام', textAlign: TextAlign.center, style: T.heading),
        const Text('مستني موافقة المشرف — الرصيد هيزيد بعد الموافقة', textAlign: TextAlign.center, style: T.sub),
        Text('$supplier · $items صنف', textAlign: TextAlign.center, style: T.sub),
        const SizedBox(height: S.m),
        Center(child: SendStatus(outboxKey: 'new_receipts:$id')),
        const SizedBox(height: S.l),
        Row(
          children: [
            Expanded(child: BigButton.light('رجوع', onPressed: () => Navigator.of(context).pop())),
            const SizedBox(width: S.s),
            Expanded(
              child: BigButton.light(
                'السجل',
                icon: Icons.history,
                onPressed: () =>
                    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HistoryScreen(kind: 'receipts'))),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
