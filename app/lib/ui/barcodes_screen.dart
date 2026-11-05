import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../util/feedback.dart';
import 'scan_helpers.dart';
import 'scope.dart';
import 'widgets.dart';

/// What one piece can be called (same list as the dashboard).
const pieceNames = ['حبة', 'علبة', 'كيس', 'زجاجة', 'باكيت'];

/// Admin only: scan a product, then scan its new barcodes (piece or carton). Saved on the server at once,
/// so it needs the network; other devices get the change on their next sync.
class BarcodesScreen extends StatefulWidget {
  const BarcodesScreen({super.key});
  @override
  State<BarcodesScreen> createState() => _BarcodesScreenState();
}

class _BarcodesScreenState extends State<BarcodesScreen> {
  Product? p;
  List<(String, String)> extra = [];
  String addMode = 'piece';
  bool busy = false;

  Future<void> _open(ScanHit? h) async {
    if (h == null || !mounted) return;
    final db = AppScope.read(context).db;
    final fresh = await db.productById(h.product.id) ?? h.product;
    final ex = await db.extraBarcodes(fresh.id);
    if (!mounted) return;
    setState(() {
      p = fresh;
      extra = ex;
      addMode = fresh.isKg ? 'kg' : (fresh.carton > 0 && !ex.any((b) => b.$2 == 'carton') ? 'carton' : 'piece');
    });
  }

  Future<bool> _send(Map<String, Object?> body) async {
    final app = AppScope.read(context);
    setState(() => busy = true);
    try {
      final r = await app.api.barcodeAction(p!.id, {...body, 'employee_id': app.employee?.id});
      if (!mounted) return false;
      if (r['ok'] != true) {
        beepError();
        toast(context, '${r['error']}');
        return false;
      }
      await app.db.saveProduct(r['product'] as Map<String, dynamic>);
      final id = p!.id;
      final fresh = await app.db.productById(id);
      final ex = await app.db.extraBarcodes(id);
      if (!mounted) return false;
      setState(() {
        p = fresh;
        extra = ex;
        if (addMode == 'carton' && (fresh?.carton ?? 0) == 0) addMode = 'piece';
      });
      beepOk();
      toast(context, '${r['msg']}');
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      beepError();
      toast(
        context,
        e.code == 'forbidden'
            ? 'الباركودات للمدير بس'
            : (e.code == 'offline' ? 'لازم تكون متصل بالشبكة علشان تعدّل الباركود' : 'حصل خطأ في السيرفر، جرّب تاني'),
      );
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _onScan(String code) async {
    if (busy) return;
    if (p == null) return _open(await findScanned(context, AppScope.read(context), code));
    await _send({'action': 'add', 'code': code, 'mode': addMode});
  }

  Future<void> _type() async {
    final code = await typeBarcode(context);
    if (code != null && code.isNotEmpty) await _onScan(code);
  }

  Future<void> _unit() async {
    final pr = p!;
    final name = await showAppSheet<String>(
      context,
      Builder(
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('اسم الوحدة', style: T.heading),
            const Text('زي فاتورة الوزارة: علبة للحليب، حبة لمعجون الطماطم', style: T.sub),
            const SizedBox(height: S.s),
            for (final n in pieceNames)
              Padding(
                padding: const EdgeInsets.only(bottom: S.xs),
                child: n == pr.pieceName
                    ? BigButton(n, icon: Icons.check, onPressed: () => Navigator.pop(ctx, n))
                    : BigButton.light(n, onPressed: () => Navigator.pop(ctx, n)),
              ),
          ],
        ),
      ),
    );
    if (name == null || !mounted) return;
    await _send({'action': 'unit', 'piece_name': name, 'carton': pr.carton});
  }

  Future<void> _carton() async {
    final pr = p!;
    final r = await numberPad(
      context,
      title: 'عدد ${pr.pieceName} في الكرتون',
      hint: '0 لو الصنف مالوش كرتون',
      initial: pr.carton * 1000,
      allowZero: true,
      pieceName: pr.pieceName,
      ok: 'حفظ',
    );
    if (r == null || !mounted) return;
    if (r.qty % 1000 != 0) {
      toast(context, 'العدد لازم يكون رقم صحيح');
      return;
    }
    await _send({'action': 'unit', 'piece_name': pr.pieceName, 'carton': r.qty ~/ 1000});
  }

  Future<void> _remove(String code) async {
    final ok = await confirmSheet(context, title: 'تشيل الباركود $code؟', yes: 'نعم، شيله', danger: true);
    if (ok && mounted) await _send({'action': 'remove', 'code': code});
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final pr = p;
    final codes = pr == null
        ? <(String, String, bool)>[]
        : [(pr.barcode, pr.isKg ? 'kg' : 'piece', true), for (final b in extra) (b.$1, b.$2, false)];
    return WorkScaffold(
      title: 'الباركودات',
      onScan: _onScan,
      body: ListView(
        padding: const EdgeInsets.all(S.edge),
        children: [
          if (pr == null)
            ScanPrompt(
              title: 'امسح الصنف اللي عايز تعدّل باركوداته',
              sub: 'أو دوّر بالاسم',
              onType: () async => _open(await typeAndFind(context, app)),
              onSearch: () async => _open(await searchAndPick(context, app)),
            )
          else ...[
            CardBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(pr.name, style: T.heading),
                  const SizedBox(height: S.xs),
                  Wrap(
                    spacing: S.s,
                    runSpacing: S.xs,
                    children: [
                      if (pr.isKg)
                        const Pill('بالكيلو')
                      else ...[
                        ActionChip(
                          avatar: const Icon(Icons.edit_outlined, size: 18),
                          label: Text('الوحدة: ${pr.pieceName}'),
                          onPressed: busy ? null : _unit,
                        ),
                        ActionChip(
                          avatar: const Icon(Icons.edit_outlined, size: 18),
                          label: Text(pr.carton > 0 ? 'الكرتون: ${pr.carton} ${pr.pieceName}' : 'مالوش كرتون'),
                          onPressed: busy ? null : _carton,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: S.s),
            Material(
              color: cBlue2,
              borderRadius: BorderRadius.circular(S.radius),
              child: Padding(
                padding: const EdgeInsets.all(S.m),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('الباركود اللي هتمسحه هيتضاف لـ «${pr.name}» كـ:', style: T.label.copyWith(color: cBlue)),
                    const SizedBox(height: S.xs),
                    if (!pr.isKg)
                      SegmentedButton<String>(
                        key: const Key('add_mode'),
                        segments: [
                          ButtonSegment(value: 'piece', label: Text(pr.pieceName)),
                          ButtonSegment(value: 'carton', label: const Text('كرتون'), enabled: pr.carton > 0),
                        ],
                        selected: {addMode},
                        onSelectionChanged: (v) => setState(() => addMode = v.first),
                      )
                    else
                      const Text('كيلو', style: T.heading),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(top: S.s),
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: S.s),
            BigButton.light('اكتب الباركود بالإيد', icon: Icons.keyboard_outlined, onPressed: busy ? null : _type),
            const SizedBox(height: S.s),
            for (final c in codes)
              ItemRow(
                key: ValueKey(c.$1),
                title: c.$1,
                details: Text('${pr.unitName(c.$2)}${c.$3 ? ' · الأساسي' : ''}'),
                controls: IconBox(Icons.delete_outline, label: 'شيل ${c.$1}', fg: cRed, onPressed: busy ? null : () => _remove(c.$1)),
              ),
            const SizedBox(height: S.m),
            BigButton.light('صنف تاني', icon: Icons.swap_horiz, onPressed: () => setState(() => p = null)),
          ],
        ],
      ),
    );
  }
}
