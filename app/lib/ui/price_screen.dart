import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/format.dart';
import 'scan_helpers.dart';
import 'scope.dart';
import 'widgets.dart';

class PriceScreen extends StatefulWidget {
  final Product? initial;
  const PriceScreen({super.key, this.initial});
  @override
  State<PriceScreen> createState() => _PriceScreenState();
}

class _PriceScreenState extends State<PriceScreen> {
  late Product? p = widget.initial;

  Future<void> _show(Future<Product?> f) async {
    final r = await f;
    if (r != null && mounted) setState(() => p = r);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    Future<void> type() => _show(typeAndFind(context, app));
    Future<void> search() => _show(searchAndPick(context, app));
    return ScanListener(
      onScan: (code) => _show(findScanned(context, app, code)),
      child: Scaffold(
        appBar: topBar(context, 'سعر صنف'),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          if (p == null)
            ScanPrompt(title: 'امسح باركود الصنف', sub: 'السعر سيظهر هنا بخط كبير', onType: type, onSearch: search)
          else ...[
            ScanBar(text: 'امسح صنفاً آخر', onType: type, onSearch: search),
            CardBox(
              padding: const EdgeInsets.all(18),
              child: Column(children: [
                Text(p!.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text.rich(
                    TextSpan(children: [
                      TextSpan(text: money(p!.price), style: const TextStyle(fontSize: 58, fontWeight: FontWeight.w800, color: cGreen)),
                      const TextSpan(text: ' د.ك', style: TextStyle(fontSize: 24, color: cGreen)),
                    ]),
                    textAlign: TextAlign.center),
                Text(p!.isKg ? 'للكيلو' : 'للحبة', style: const TextStyle(fontSize: 19, color: cMuted)),
                const SizedBox(height: 10),
                if (p!.carton > 0) _kv('الكرتون (${p!.carton} حبة)', '${money(p!.price * p!.carton)} د.ك'),
                _kv('في المخزن', p!.baseText(p!.stock)),
                _kv('الباركود', p!.barcode),
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _kv(String k, String v) => Container(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: cLine))),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Row(children: [
          Expanded(child: Text(k, style: const TextStyle(fontSize: 19))),
          Flexible(child: Text(v, textAlign: TextAlign.left, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
        ]),
      );
}
