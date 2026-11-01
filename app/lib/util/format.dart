// Money is kept in fils (1/1000 KWD) and quantities in thousandths, as integers,
// so totals never suffer from floating point rounding.

const unitNames = {'piece': 'حبة', 'carton': 'كرتون', 'kg': 'كجم'};
const perUnit = {'piece': 'للحبة', 'carton': 'للكرتون', 'kg': 'للكيلو'};

String money(int fils) {
  final neg = fils < 0;
  final a = fils.abs();
  return '${neg ? '-' : ''}${a ~/ 1000}.${(a % 1000).toString().padLeft(3, '0')}';
}

/// Parses "2.450" -> 2450. Returns null when not a number.
int? parseMilli(String s) {
  s = s.trim();
  if (s.isEmpty) return null;
  final m = RegExp(r'^(-?)(\d+)(?:\.(\d{0,3})\d*)?$').firstMatch(s);
  if (m == null) return null;
  final whole = int.parse(m.group(2)!);
  final frac = int.parse((m.group(3) ?? '').padRight(3, '0'));
  final v = whole * 1000 + frac;
  return m.group(1) == '-' ? -v : v;
}

String milliToString(int v) => money(v);

/// Quantity for display: whole numbers without decimals, weights with 3 decimals.
String qty(int milli, String mode) {
  if (mode == 'kg') return money(milli);
  if (milli % 1000 == 0) return '${milli ~/ 1000}';
  return money(milli);
}

String qtyText(int milli, String mode) => '${qty(milli, mode)} ${unitNames[mode]}';

/// price (fils) x quantity (milli), rounded half up to whole fils.
int lineTotal(int priceFils, int qtyMilli) {
  final p = priceFils * qtyMilli;
  return p >= 0 ? (p + 500) ~/ 1000 : -((-p + 500) ~/ 1000);
}
