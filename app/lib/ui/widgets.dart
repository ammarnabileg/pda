import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../util/format.dart';

// ---------- colours ----------
const cHead = Color(0xFF123F37);
const cGreen = Color(0xFF0A6B3D);
const cGreen2 = Color(0xFFE1F2E8);
const cRed = Color(0xFFB42318);
const cRed2 = Color(0xFFFDECEB);
const cOrange = Color(0xFF9A5200);
const cOrange2 = Color(0xFFFFF0DC);
const cBlue = Color(0xFF1D4FD8);
const cBlue2 = Color(0xFFE5ECFD);
const cBg = Color(0xFFEEF1EF);
const cLine = Color(0xFFCDD6D1);
const cMuted = Color(0xFF4A5751);
const cGray2 = Color(0xFFEEF2F0);

ThemeData appTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: cGreen, primary: cGreen, surface: Colors.white),
    scaffoldBackgroundColor: cBg,
    fontFamily: null,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: const Color(0xFF14201B), displayColor: const Color(0xFF14201B)),
    appBarTheme: const AppBarTheme(backgroundColor: cHead, foregroundColor: Colors.white, toolbarHeight: 68),
  );
}

// ---------- scanner ----------

/// Reads the built-in scanner in "keyboard wedge" mode. This is how every work screen
/// receives barcodes; no text box or button is needed.
///
/// Honeywell (and similar) wedges deliver the code in one of two ways, depending on the
/// device profile. Both are handled:
///  * key events: caught with [HardwareKeyboard] anywhere on the screen;
///  * text injected into the focused field: caught by an invisible, always-focused field
///    that never opens the on-screen keyboard.
/// The code ends at Enter/Tab. If the scanner is set up without a suffix, a burst of
/// characters typed at scanner speed is taken as a scan once it stops.
class ScanListener extends StatefulWidget {
  final Widget child;
  final void Function(String code) onScan;
  const ScanListener({super.key, required this.child, required this.onScan});

  @override
  State<ScanListener> createState() => _ScanListenerState();
}

/// Scanners type a whole code in well under this per character; people cannot.
const _scannerKeyGap = Duration(milliseconds: 60);
const _idleEnd = Duration(milliseconds: 120);
const _minLength = 4;

class _ScanListenerState extends State<ScanListener> {
  final _buf = StringBuffer();
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  bool _allFast = true;
  Timer? _idle;
  final _field = TextEditingController();
  final _focus = FocusNode(debugLabel: 'scanner');

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    FocusManager.instance.addListener(_keepFocus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _keepFocus());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    FocusManager.instance.removeListener(_keepFocus);
    _idle?.cancel();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _active {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  /// Gives the invisible field the focus whenever nothing else needs it.
  void _keepFocus() {
    if (!_active || _focus.hasFocus) return;
    final f = FocusManager.instance.primaryFocus;
    if (f != null && f.context?.widget is EditableText) return; // a real text box is in use
    _focus.requestFocus();
  }

  bool _otherTextBoxFocused() {
    final f = FocusManager.instance.primaryFocus;
    return f != null && f != _focus && f.context?.widget is EditableText;
  }

  void _finish() {
    _idle?.cancel();
    final code = _buf.toString().trim();
    _buf.clear();
    _allFast = true;
    if (code.length >= _minLength) widget.onScan(code);
  }

  void _addChar(String ch) {
    final now = DateTime.now();
    final gap = now.difference(_last);
    if (gap > const Duration(milliseconds: 1500)) {
      _buf.clear();
      _allFast = true;
    } else if (_buf.isNotEmpty && gap > _scannerKeyGap) {
      _allFast = false; // a person typing on a hardware keypad
    }
    _last = now;
    _buf.write(ch);
    // No Enter from the scanner: end the code when a fast burst stops.
    _idle?.cancel();
    _idle = Timer(_idleEnd, () {
      if (_allFast && _buf.length >= 8) _finish();
    });
  }

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || !_active || _otherTextBoxFocused()) return false;
    if (e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.numpadEnter ||
        e.logicalKey == LogicalKeyboardKey.tab) {
      if (_buf.isEmpty) return false;
      _finish();
      return true;
    }
    final ch = e.character;
    if (ch != null && RegExp(r'^[0-9A-Za-z.\-]$').hasMatch(ch)) {
      _addChar(ch);
      return true; // handled here, so the invisible field does not get it twice
    }
    return false;
  }

  /// Text injected by the scanner into the invisible field.
  void _onFieldChanged(String text) {
    if (text.isEmpty) return;
    _field.clear();
    for (final ch in text.split('')) {
      if (ch == '\n' || ch == '\r' || ch == '\t') {
        _finish();
      } else if (RegExp(r'^[0-9A-Za-z.\-]$').hasMatch(ch)) {
        _addChar(ch);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      Positioned(
        left: 0,
        top: 0,
        width: 1,
        height: 1,
        child: Opacity(
          opacity: 0,
          child: ExcludeSemantics(
            child: Material(
              type: MaterialType.transparency,
              child: TextField(
                key: const Key('scanner-input'),
                controller: _field,
                focusNode: _focus,
                autofocus: true,
                keyboardType: TextInputType.none, // never show the on-screen keyboard
                showCursor: false,
                enableInteractiveSelection: false,
                autocorrect: false,
                enableSuggestions: false,
                maxLines: 1,
                textInputAction: TextInputAction.done,
                onChanged: _onFieldChanged,
                onSubmitted: (_) {
                  _finish();
                  _focus.requestFocus();
                },
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

// ---------- layout pieces ----------

PreferredSizeWidget topBar(BuildContext context, String title, {List<Widget>? actions, bool back = true}) {
  return AppBar(
    automaticallyImplyLeading: false,
    titleSpacing: 12,
    title: Row(
      children: [
        if (back)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 10),
            child: Material(
              color: Colors.white.withValues(alpha: .15),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.of(context).maybePop(),
                child: const SizedBox(
                  height: 52,
                  child: Padding(
                    padding: EdgeInsetsDirectional.only(start: 8, end: 14),
                    child: Row(
                      children: [
                        Icon(Icons.chevron_right, size: 30, color: Colors.white),
                        Text(
                          'رجوع',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
          ),
        ),
      ],
    ),
    actions: actions,
  );
}

class BigButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color color;
  final Color textColor;
  final bool outline;
  final double height;
  const BigButton(
    this.label, {
    super.key,
    this.icon,
    this.onPressed,
    this.color = cGreen,
    this.textColor = Colors.white,
    this.outline = false,
    this.height = 64,
  });

  const BigButton.light(this.label, {super.key, this.icon, this.onPressed, this.height = 64})
    : color = Colors.white,
      textColor = const Color(0xFF14201B),
      outline = true;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: textColor,
          disabledBackgroundColor: color.withValues(alpha: .4),
          disabledForegroundColor: textColor.withValues(alpha: .7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: outline ? const BorderSide(color: cLine, width: 2) : BorderSide.none,
          ),
          textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, size: 28), const SizedBox(width: 8)],
            Flexible(child: Text(label, textAlign: TextAlign.center)),
          ],
        ),
      ),
    );
  }
}

class CardBox extends StatelessWidget {
  final Widget child;
  final Color border;
  final Color? color;
  final EdgeInsets padding;
  const CardBox({super.key, required this.child, this.border = cLine, this.color, this.padding = const EdgeInsets.all(12)});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: padding,
    decoration: BoxDecoration(
      color: color ?? Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: border, width: 2),
    ),
    child: child,
  );
}

class Pill extends StatelessWidget {
  final String text;
  final Color fg, bg;
  const Pill(this.text, {super.key, this.fg = cMuted, this.bg = cGray2});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
    child: Text(
      text,
      style: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w800),
    ),
  );
}

/// Footer pinned to the bottom with a white background.
class Footer extends StatelessWidget {
  final List<Widget> children;
  const Footer({super.key, required this.children});
  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: cLine, width: 2)),
    ),
    padding: EdgeInsets.fromLTRB(12, 10, 12, 10 + MediaQuery.of(context).padding.bottom),
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

class ScanPrompt extends StatelessWidget {
  final String title, sub;
  final VoidCallback onType, onSearch;
  const ScanPrompt({super.key, required this.title, required this.sub, required this.onType, required this.onSearch});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF93AA9E), width: 3),
        ),
        child: Column(
          children: [
            const Icon(Icons.qr_code_scanner, size: 90, color: cHead),
            const SizedBox(height: 6),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: cHead),
            ),
            Text(
              sub,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, color: cMuted),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _AltButtons(onType: onType, onSearch: onSearch),
    ],
  );
}

class ScanBar extends StatelessWidget {
  final String text;
  final VoidCallback onType, onSearch;
  const ScanBar({super.key, required this.text, required this.onType, required this.onSearch});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFF93AA9E), width: 2),
    ),
    child: Row(
      children: [
        const Icon(Icons.qr_code_scanner, size: 30, color: cHead),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: cHead),
          ),
        ),
        _small(Icons.dialpad, 'رقم', onType),
        const SizedBox(width: 6),
        _small(Icons.search, 'اسم', onSearch),
      ],
    ),
  );

  Widget _small(IconData i, String t, VoidCallback f) => Material(
    color: cGray2,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: f,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(i, size: 22),
              const SizedBox(width: 4),
              Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AltButtons extends StatelessWidget {
  final VoidCallback onType, onSearch;
  const _AltButtons({required this.onType, required this.onSearch});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: BigButton.light('اكتب الرقم', icon: Icons.dialpad, onPressed: onType, height: 58),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: BigButton.light('ابحث بالاسم', icon: Icons.search, onPressed: onSearch, height: 58),
      ),
    ],
  );
}

// ---------- sheets ----------

Future<T?> _sheet<T>(BuildContext context, Widget child, {bool dismissible = true}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  isDismissible: dismissible,
  enableDrag: dismissible,
  backgroundColor: Colors.white,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
  builder: (_) => SafeArea(
    child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(14, 16, 14, 14), child: child),
  ),
);

Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  Widget? body,
  required String yes,
  String no = 'رجوع',
  bool danger = false,
}) async {
  final r = await _sheet<bool>(
    context,
    Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (danger) Container(height: 8, margin: const EdgeInsets.only(bottom: 12), color: cRed),
        Text(
          title,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: danger ? cRed : null),
        ),
        if (body != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 20), child: body),
          ),
        const SizedBox(height: 8),
        Builder(
          builder: (ctx) => Row(
            children: [
              Expanded(child: BigButton.light(no, onPressed: () => Navigator.pop(ctx, false))),
              const SizedBox(width: 10),
              Expanded(
                child: BigButton(yes, color: danger ? cRed : cGreen, onPressed: () => Navigator.pop(ctx, true)),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<void> alertSheet(BuildContext context, {required String title, Widget? body}) => _sheet<void>(
  context,
  Builder(
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 8, margin: const EdgeInsets.only(bottom: 12), color: cRed),
        Text(
          title,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: cRed),
        ),
        if (body != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 20), child: body),
          ),
        const SizedBox(height: 8),
        BigButton.light('حسناً', onPressed: () => Navigator.pop(ctx)),
      ],
    ),
  ),
);

class PadResult {
  final int qty; // thousandths
  final String mode;

  /// Set when a barcode was scanned while the pad was open: the pad closes
  /// without saving and the caller should treat this as a new scan.
  final String? scanned;
  const PadResult(this.qty, this.mode, {this.scanned});
}

/// Big number pad. Returns null when cancelled.
Future<PadResult?> numberPad(
  BuildContext context, {
  required String title,
  String? hint,
  List<String> modes = const ['piece'],
  String? mode,
  int? initial,
  bool allowZero = false,
  bool barcode = false,
  String ok = 'حفظ',
}) {
  return _sheet<PadResult>(
    context,
    _NumberPad(
      title: title,
      hint: hint,
      modes: modes,
      mode: mode ?? modes.first,
      initial: initial,
      allowZero: allowZero,
      barcode: barcode,
      ok: ok,
    ),
    dismissible: false,
  );
}

/// Returns a typed barcode.
Future<String?> typeBarcode(BuildContext context) async {
  final r = await _sheet<PadResult>(context, const _BarcodePad(), dismissible: false);
  return r?.mode;
}

class _NumberPad extends StatefulWidget {
  final String title;
  final String? hint;
  final List<String> modes;
  final String mode;
  final int? initial;
  final bool allowZero, barcode;
  final String ok;
  const _NumberPad({
    required this.title,
    this.hint,
    required this.modes,
    required this.mode,
    this.initial,
    required this.allowZero,
    required this.barcode,
    required this.ok,
  });
  @override
  State<_NumberPad> createState() => _NumberPadState();
}

class _NumberPadState extends State<_NumberPad> {
  late String mode = widget.mode;
  late String value = widget.initial == null ? '' : qty(widget.initial!, mode).replaceAll(RegExp(r'\.?0+$'), '');
  String? err;
  final _kb = StringBuffer();
  DateTime _kbLast = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  // Hardware keypads on PDAs can type straight into the pad.
  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final ch = e.character;
    final now = DateTime.now();
    if (now.difference(_kbLast) > const Duration(milliseconds: 1500)) _kb.clear();
    _kbLast = now;
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final typed = _kb.toString();
      _kb.clear();
      if (!widget.barcode && typed.length >= 6) {
        // That was the scanner, not someone typing a quantity.
        Navigator.pop(context, PadResult(0, mode, scanned: typed));
      } else if (widget.barcode && typed.length >= 4) {
        Navigator.pop(context, PadResult(0, typed));
      } else {
        _save();
      }
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace) {
      _press('back');
      return true;
    }
    if (ch != null && RegExp(r'^[0-9A-Za-z.\-]$').hasMatch(ch)) {
      _kb.write(ch);
      if (RegExp(r'^[0-9.]$').hasMatch(ch)) _press(ch);
      return true;
    }
    return false;
  }

  void _press(String k) {
    setState(() {
      err = null;
      if (k == 'back') {
        if (value.isNotEmpty) value = value.substring(0, value.length - 1);
      } else if (k == 'clear') {
        value = '';
      } else if (k == '.') {
        if (mode == 'kg' && !value.contains('.')) value = '${value.isEmpty ? '0' : value}.';
      } else {
        if (value.length >= (widget.barcode ? 14 : 7)) return;
        if (value.contains('.') && value.split('.')[1].length >= 3) return;
        value = value == '0' ? k : value + k;
      }
    });
  }

  void _save() {
    if (widget.barcode) {
      if (value.length < 4) {
        setState(() => err = 'الرقم قصير، اكتب رقم الباركود كاملاً');
        return;
      }
      Navigator.pop(context, PadResult(0, value));
      return;
    }
    final v = parseMilli(value);
    if (v == null || v < 0 || (v == 0 && !widget.allowZero)) {
      setState(() => err = 'اكتب الكمية أولاً');
      return;
    }
    Navigator.pop(context, PadResult(v, mode));
  }

  @override
  Widget build(BuildContext context) {
    final kg = mode == 'kg';
    final keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', widget.barcode ? 'clear' : (kg ? '.' : 'clear'), '0', 'back'];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        if (widget.hint != null) Text(widget.hint!, style: const TextStyle(fontSize: 18, color: cMuted)),
        const SizedBox(height: 10),
        if (widget.modes.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: widget.modes
                  .map(
                    (m) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: SizedBox(
                          height: 56,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: m == mode ? cGreen : Colors.white,
                              foregroundColor: m == mode ? Colors.white : Colors.black,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: m == mode ? cGreen : cLine, width: 2),
                              ),
                              textStyle: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                            ),
                            onPressed: () => setState(() {
                              mode = m;
                              if (m != 'kg' && value.contains('.')) value = value.split('.')[0];
                            }),
                            child: Text(unitNames[m]!),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        Container(
          height: 70,
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            border: Border.all(color: cLine, width: 2),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value.isEmpty ? '0' : value,
                textDirection: TextDirection.ltr,
                style: TextStyle(fontSize: 44, fontWeight: FontWeight.w800, color: value.isEmpty ? const Color(0xFFB8C2BD) : null),
              ),
              if (!widget.barcode) ...[
                const SizedBox(width: 10),
                Text(unitNames[mode]!, style: const TextStyle(fontSize: 22, color: cMuted)),
              ],
            ],
          ),
        ),
        if (err != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              err!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: cRed, fontSize: 19, fontWeight: FontWeight.w800),
            ),
          ),
        Directionality(
          textDirection: TextDirection.ltr,
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 2.1,
            children: keys
                .map(
                  (k) => Material(
                    color: cGray2,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _press(k),
                      child: Center(
                        child: k == 'back'
                            ? const Icon(Icons.backspace_outlined, size: 28)
                            : Text(
                                k == 'clear' ? 'مسح الكل' : k,
                                style: TextStyle(fontSize: k.length > 1 ? 20 : 30, fontWeight: FontWeight.w800),
                              ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: BigButton.light('إلغاء', onPressed: () => Navigator.pop(context))),
            const SizedBox(width: 10),
            Expanded(child: BigButton(widget.ok, onPressed: _save)),
          ],
        ),
      ],
    );
  }
}

class _BarcodePad extends StatelessWidget {
  const _BarcodePad();
  @override
  Widget build(BuildContext context) => _NumberPad(
    title: 'اكتب رقم الباركود',
    hint: 'الرقم المكتوب تحت الخطوط',
    modes: const ['piece'],
    mode: 'piece',
    allowZero: false,
    barcode: true,
    ok: 'بحث',
  );
}

/// Picks a product by typing part of its name. Returns the product or null.
Future<Product?> searchProductSheet(BuildContext context, Future<List<Product>> Function(String q) search) =>
    _sheet<Product>(context, _SearchSheet(search));

class _SearchSheet extends StatefulWidget {
  final Future<List<Product>> Function(String q) search;
  const _SearchSheet(this.search);
  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  List<Product> items = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _run('');
  }

  void _run(String q) async {
    final r = await widget.search(q);
    if (mounted) setState(() => items = r);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * .8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('ابحث باسم الصنف', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          TextField(
            autofocus: true,
            style: const TextStyle(fontSize: 22),
            decoration: InputDecoration(
              hintText: 'مثال: أرز',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              contentPadding: const EdgeInsets.all(14),
            ),
            onChanged: (q) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), () => _run(q));
            },
          ),
          const SizedBox(height: 8),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text('لا يوجد صنف بهذا الاسم', style: TextStyle(fontSize: 19, color: cMuted)),
                  )
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = items[i];
                      return ListTile(
                        minVerticalPadding: 12,
                        title: Text(p.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        subtitle: Text('${money(p.price)} د.ك ${p.isKg ? 'للكيلو' : 'للحبة'}', style: const TextStyle(fontSize: 16)),
                        onTap: () => Navigator.pop(context, p),
                      );
                    },
                  ),
          ),
          BigButton.light('إلغاء', onPressed: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}

/// Short message at the top, with an optional undo button.
void toast(BuildContext context, String msg, {VoidCallback? undo}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
      duration: Duration(seconds: undo == null ? 2 : 6),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF16302A),
      action: undo == null ? null : SnackBarAction(label: 'تراجع', textColor: Colors.white, onPressed: undo),
    ),
  );
}
