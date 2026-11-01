import 'package:flutter/material.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../util/feedback.dart';
import 'widgets.dart';

/// Looks a scanned code up; on failure beeps and shows a red message.
Future<Product?> findScanned(BuildContext context, AppState app, String code) async {
  final p = await app.db.productByBarcode(code);
  if (p != null) {
    beepOk();
    return p;
  }
  beepError();
  if (context.mounted) {
    await alertSheet(context,
        title: 'الصنف غير مسجل',
        body: Text.rich(TextSpan(children: [
          const TextSpan(text: 'هذا الباركود غير موجود على الجهاز:\n'),
          TextSpan(text: code, style: const TextStyle(fontWeight: FontWeight.w800)),
          const TextSpan(text: '\nلو الصنف جديد، اطلب من المشرف إضافته ثم انتظر المزامنة.'),
        ])));
  }
  return null;
}

Future<Product?> typeAndFind(BuildContext context, AppState app) async {
  final code = await typeBarcode(context);
  if (code == null || !context.mounted) return null;
  return findScanned(context, app, code);
}

Future<Product?> searchAndPick(BuildContext context, AppState app) => searchProductSheet(context, (q) => app.db.searchProducts(q));
