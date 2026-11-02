import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/format.dart';
import 'scan_helpers.dart';
import 'scope.dart';
import 'widgets.dart';

/// "When was this data last refreshed", shown wherever stock is shown: offline,
/// the number on the device can be behind the server.
String syncedAgo(DateTime? t) {
  if (t == null) return 'لسه ماحصلش ${W.sync}';
  final m = DateTime.now().difference(t).inMinutes;
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (m < 1) return 'آخر ${W.sync}: الآن';
  if (m < 60) return 'آخر ${W.sync}: من $m دقيقة ($hm)';
  return 'آخر ${W.sync}: ${t.day}/${t.month} $hm';
}

class PriceScreen extends StatefulWidget {
  final ScanHit? initial;
  const PriceScreen({super.key, this.initial});
  @override
  State<PriceScreen> createState() => _PriceScreenState();
}

class _PriceScreenState extends State<PriceScreen> {
  late Product? p = widget.initial?.product;
  late String? scannedMode = widget.initial?.mode;

  Future<void> _show(Future<ScanHit?> f) async {
    final r = await f;
    if (r != null && mounted) {
      setState(() {
        p = r.product;
        scannedMode = r.mode;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    Future<void> type() => _show(typeAndFind(context, app));
    Future<void> search() => _show(searchAndPick(context, app));
    final unit = p?.isKg == true ? 'كجم' : 'حبة';
    return WorkScaffold(
      title: 'سعر صنف',
      onScan: (code) => _show(findScanned(context, app, code)),
      body: ListView(
        padding: const EdgeInsets.all(S.edge),
        children: [
          if (p == null)
            ScanPrompt(title: 'امسح الصنف', sub: 'السعر هيظهر هنا', onType: type, onSearch: search)
          else ...[
            ScanBar(text: 'امسح الصنف التالي', onType: type, onSearch: search),
            CardBox(
              padding: const EdgeInsets.all(S.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(p!.name, textAlign: TextAlign.center, style: T.heading.copyWith(fontSize: 20)),
                  if (scannedMode == 'carton') ...[
                    const SizedBox(height: S.xs),
                    Center(
                      child: Pill(
                        'اتمسح باركود الكرتون (${p!.carton} حبة) — سعر الكرتون ${money(p!.price * p!.carton)}',
                        fg: cBlue,
                        bg: cBlue2,
                        icon: Icons.inventory_2_outlined,
                      ),
                    ),
                  ],
                  const SizedBox(height: S.s),
                  // Shrinks instead of overflowing with large Android fonts.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(money(p!.price), textDirection: TextDirection.ltr, style: T.bigPrice),
                        Text(' ${W.currency} / $unit', style: T.heading.copyWith(color: cPrimary)),
                      ],
                    ),
                  ),
                  const SizedBox(height: S.m),
                  if (p!.carton > 0) _kv('الكرتون (${p!.carton} حبة)', '${money(p!.price * p!.carton)} ${W.currency}'),
                  _kv('سعر الشراء', '${money(p!.cost)} ${W.currency} / $unit'),
                  if (p!.carton > 0) _kv('شراء الكرتون', '${money(p!.cost * p!.carton)} ${W.currency}'),
                  _kv('الرصيد على الجهاز', p!.baseText(p!.stock)),
                  _kv('الباركود', p!.barcode),
                  const SizedBox(height: S.xs),
                  Text(syncedAgo(app.lastSync), textAlign: TextAlign.center, style: T.sub),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Container(
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: cLine)),
    ),
    padding: const EdgeInsets.symmetric(vertical: S.s),
    child: Row(
      children: [
        Expanded(child: Text(k, style: T.sub.copyWith(fontSize: 15))),
        Flexible(
          child: Text(v, textAlign: TextAlign.left, style: T.label),
        ),
      ],
    ),
  );
}
