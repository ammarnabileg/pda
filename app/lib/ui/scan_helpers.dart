import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../util/feedback.dart';
import 'widgets.dart';

/// Looks a scanned code up (main or extra barcode, with its unit);
/// on failure beeps and shows a red message.
Future<ScanHit?> findScanned(BuildContext context, AppState app, String code) async {
  final hit = await app.db.lookup(code);
  if (hit != null) {
    beepOk();
    return hit;
  }
  beepError();
  if (context.mounted) {
    final choice = await alertSheet(
      context,
      title: 'الصنف غير مسجل على الجهاز',
      action: 'ابحث بالاسم',
      body: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'الباركود: '),
            TextSpan(
              text: code,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const TextSpan(text: '\nلو الصنف جديد: المشرف يضيفه من لوحة التحكم، وبعدين اعمل مزامنة.'),
          ],
        ),
      ),
    );
    if (choice != null && context.mounted) return searchAndPick(context, app);
  }
  return null;
}

Future<ScanHit?> typeAndFind(BuildContext context, AppState app) async {
  final code = await typeBarcode(context);
  if (code == null || !context.mounted) return null;
  return findScanned(context, app, code);
}

Future<ScanHit?> searchAndPick(BuildContext context, AppState app) async {
  final p = await searchProductSheet(context, (q) => app.db.searchProducts(q));
  return p == null ? null : ScanHit(p);
}
