import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/format.dart';
import '../util/ids.dart';
import '../util/photo.dart';
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
  static const _photosKey = 'draft_new_receipt_photos';
  String? id;
  // The supplier's own invoice, asked right after the supplier and before any item.
  String? invoiceNo, invoiceTotal;
  final photos = <Map<String, Object?>>[]; // {'id', 'ct', 'data' (base64)}
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
      invoiceNo = d['inv'] as String?;
      invoiceTotal = d['inv_total'] as String?;
      for (final j in (d['lines'] as List)) {
        lines.add(_Line(j['p'] as int, j['q'] as int, j['m'] as String, j['n'] as String?));
      }
      products.addAll(await db.productsByIds(lines.map((l) => l.productId)));
      lines.removeWhere((l) => !products.containsKey(l.productId));
    }
    final ph = await db.getJson(_photosKey);
    if (ph is List) photos.addAll(ph.cast<Map<String, dynamic>>());
    if (mounted) setState(() => loaded = true);
    if (!mounted) return;
    if (supplierName.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickSupplier());
    } else if (invoiceNo == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askInvoice());
    }
  }

  /// Supplier invoice number (required) and total, before anything is scanned.
  Future<bool> _askInvoice() async {
    final r = await showAppSheet<(String, String?)>(context, _InvoiceSheet(no: invoiceNo ?? '', total: invoiceTotal ?? ''));
    if (r == null || !mounted) return invoiceNo != null;
    setState(() {
      invoiceNo = r.$1;
      invoiceTotal = r.$2;
    });
    await _save();
    return true;
  }

  Future<void> _photo() async {
    if (photos.length >= 6) {
      toast(context, 'كفاية 6 صور للفاتورة الواحدة');
      return;
    }
    final shot = await takeInvoicePhoto();
    if (shot == null || !mounted) return;
    setState(() => photos.add({'id': uuid4(), 'ct': shot.$2, 'data': base64Encode(shot.$1)}));
    await AppScope.read(context).db.setJson(_photosKey, photos);
    if (mounted) toast(context, 'تم حفظ صورة الفاتورة (${photos.length})');
  }

  Future<void> _save() {
    id ??= uuid4();
    return AppScope.read(context).db.setJson(_draftKey, {
      'id': id,
      'sid': supplierId,
      'sname': supplierName,
      'inv': invoiceNo,
      'inv_total': invoiceTotal,
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
    await _save();
    if (invoiceNo == null && mounted) await _askInvoice();
  }

  Future<void> _onProduct(ScanHit? h) async {
    if (h == null || !mounted) return;
    if (invoiceNo == null && !await _askInvoice()) return;
    if (!mounted) return;
    final p = h.product;
    products[p.id] = p;
    final existing = lines.where((l) => l.productId == p.id).firstOrNull;
    final r = await numberPad(
      context,
      title: p.name,
      pieceName: p.pieceName,
      hint: existing != null ? 'مستلم قبل كده: ${p.qtyOf(existing.qty, existing.mode)} — الجديد هيتجمع عليه' : 'اكتب الكمية اللي وصلت',
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
            Text('مستلم: ${products[l.productId]!.qtyOf(l.qty, l.mode)}', style: T.sub),
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
      final r = await numberPad(
        context,
        title: p.name,
        pieceName: p.pieceName,
        modes: p.modes,
        mode: l.mode,
        initial: l.qty,
        carton: p.carton,
      );
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
    if (invoiceNo == null && !await _askInvoice()) return;
    if (!mounted) return;
    final ok = await confirmSheet(
      context,
      title: 'تأكيد الاستلام؟',
      body: Text(
        'المورد: $supplierName\nفاتورة الشركة: $invoiceNo${invoiceTotal != null ? ' · $invoiceTotal ${W.currency}' : ''}\n'
        '${lines.length} صنف · ${photos.isEmpty ? 'من غير صورة للفاتورة' : '${photos.length} صورة للفاتورة'}.\n'
        'السند هيروح للمدير يوافق عليه من لوحة التحكم، والرصيد هيزيد بعد موافقته.',
      ),
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
      'supplier_invoice_no': invoiceNo,
      'supplier_invoice_total': ?invoiceTotal,
      'employee_id': app.employee?.id,
      'received_at': DateTime.now().toUtc().toIso8601String(),
      'lines': [
        for (final l in lines) {'product_id': l.productId, 'mode': l.mode, 'qty': money(l.qty), if (l.note != null) 'note': l.note},
      ],
    });
    // The photos go up after the voucher (the server needs the voucher first).
    for (final ph in photos) {
      await app.db.enqueue('receipt_files', '${ph['id']}', {
        'receipt_client_id': rid,
        'file_id': ph['id'],
        'content_type': ph['ct'],
        'data': ph['data'],
      });
    }
    // No local stock change: the supervisor approves the voucher first.
    await app.db.addHistory('new_receipts', rid, {
      'supplier': supplierName,
      'invoice_no': invoiceNo,
      'photos': photos.length,
      'employee': app.employee?.name,
      'diffs': 0,
      'lines': [
        for (final l in lines)
          {
            'product_id': l.productId,
            'name': products[l.productId]!.name,
            'received': products[l.productId]!.qtyOf(l.qty, l.mode),
            'status': 'مستني موافقة المشرف',
            'note': l.note,
          },
      ],
    });
    await app.db.set(_draftKey, null);
    await app.db.set(_photosKey, null);
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
    if (!mounted) return;
    await AppScope.read(context).db.set(_photosKey, null);
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
                if (supplierName.isNotEmpty)
                  ItemRow(
                    key: const Key('invoice'),
                    title: invoiceNo == null ? 'اكتب رقم فاتورة الشركة' : 'فاتورة الشركة رقم $invoiceNo',
                    details: Text(
                      '${invoiceTotal != null ? 'الإجمالي $invoiceTotal ${W.currency} · ' : ''}'
                      '${photos.isEmpty ? 'مفيش صورة لسه' : '${photos.length} صورة'}',
                    ),
                    controls: IconBox(Icons.photo_camera_outlined, label: 'صوّر الفاتورة', onPressed: _photo),
                    onTap: _askInvoice,
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
                          TextSpan(text: products[l.productId]!.qtyOf(l.qty, l.mode), style: T.subStrong),
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
            onPressed: lines.isEmpty || supplierName.isEmpty || invoiceNo == null ? null : _finish,
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

class _InvoiceSheet extends StatefulWidget {
  final String no, total;
  const _InvoiceSheet({required this.no, required this.total});
  @override
  State<_InvoiceSheet> createState() => _InvoiceSheetState();
}

class _InvoiceSheetState extends State<_InvoiceSheet> {
  late final noCtl = TextEditingController(text: widget.no);
  late final totalCtl = TextEditingController(text: widget.total);
  String? noError, totalError;

  @override
  void dispose() {
    noCtl.dispose();
    totalCtl.dispose();
    super.dispose();
  }

  void _ok() {
    final no = noCtl.text.trim();
    final raw = totalCtl.text.trim().replaceAll(',', '.');
    // Kuwaiti dinar: at most 3 decimals (fils), read exactly, never rounded.
    final fils = RegExp(r'^\d+(\.\d{1,3})?$').hasMatch(raw) ? parseMilli(raw) : null;
    setState(() {
      noError = no.isEmpty ? 'رقم فاتورة الشركة مطلوب' : null;
      totalError = raw.isNotEmpty && fils == null ? 'اكتب المبلغ بالدينار، 3 أرقام عشرية بالكتير (مثال 44.100)' : null;
    });
    if (noError != null || totalError != null) return;
    Navigator.pop(context, (no, fils == null ? null : money(fils)));
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('فاتورة الشركة', style: T.heading),
      const Text('اكتب رقم الفاتورة اللي جت مع البضاعة. نفس الرقم مايتسجلش مرتين.', style: T.sub),
      const SizedBox(height: S.s),
      TextField(
        key: const Key('invoice_no'),
        controller: noCtl,
        autofocus: true,
        maxLength: 60,
        style: T.heading,
        textInputAction: TextInputAction.next,
        onTapOutside: (_) => hideKeyboard(),
        decoration: InputDecoration(labelText: 'رقم فاتورة الشركة', errorText: noError, counterText: ''),
      ),
      TextField(
        key: const Key('invoice_total'),
        controller: totalCtl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        onTapOutside: (_) => hideKeyboard(),
        onSubmitted: (_) {
          hideKeyboard();
          _ok();
        },
        decoration: InputDecoration(labelText: 'إجمالي الفاتورة (${W.currency}) — اختياري', errorText: totalError),
      ),
      const SizedBox(height: S.s),
      BigButton('متابعة', icon: Icons.arrow_back, onPressed: _ok),
    ],
  );
}
