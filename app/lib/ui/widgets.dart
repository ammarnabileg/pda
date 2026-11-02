import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../util/format.dart';
import 'design.dart';
import 'scope.dart';
import 'settings_screen.dart';

export 'design.dart';

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

/// Same top bar on every screen: back on the right, short title, sync status on the left.
PreferredSizeWidget topBar(BuildContext context, String title, {bool back = true, bool sync = true}) {
  return AppBar(
    automaticallyImplyLeading: false,
    titleSpacing: S.s,
    title: Row(
      children: [
        if (back)
          Semantics(
            button: true,
            label: W.back,
            child: InkWell(
              borderRadius: BorderRadius.circular(S.radius),
              onTap: () => Navigator.of(context).maybePop(),
              child: const SizedBox(
                height: S.touch,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(start: 2, end: S.s),
                  child: Row(
                    children: [
                      Icon(Icons.arrow_forward, size: 24, color: Colors.white),
                      SizedBox(width: S.xs),
                      Text(
                        W.back,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (back)
          Container(
            width: 1,
            height: 24,
            color: Colors.white24,
            margin: const EdgeInsetsDirectional.only(end: S.s),
          ),
        Expanded(
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.pageTitle),
        ),
        if (sync) const SyncIndicator(),
      ],
    ),
  );
}

/// Small connection state with the number of records still waiting. Tap: sync details.
class SyncIndicator extends StatelessWidget {
  const SyncIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final (IconData icon, String text, Color bg) = switch (app.status) {
      SyncStatus.syncing => (Icons.sync, 'مزامنة', Colors.white24),
      SyncStatus.ok => (Icons.cloud_done_outlined, 'متصل', Colors.white24),
      SyncStatus.offline => (Icons.cloud_off_outlined, 'غير متصل', cRed),
      SyncStatus.unpaired => (Icons.link_off, 'غير مربوط', cRed),
      SyncStatus.error => (Icons.error_outline, 'خطأ', cRed),
      SyncStatus.idle => (Icons.cloud_queue, '…', Colors.white24),
    };
    final pending = app.pending;
    return Semantics(
      button: true,
      label: 'حالة المزامنة: $text${pending > 0 ? '، $pending مستنية' : ''}',
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(99),
        child: InkWell(
          borderRadius: BorderRadius.circular(99),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40, minWidth: S.touch),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: Colors.white),
                  const SizedBox(width: S.xs),
                  Text(
                    text,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  if (pending > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(99)),
                      child: Text(
                        '$pending',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: cHead),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin strip under the top bar when the device cannot reach the server.
class OfflineStrip extends StatelessWidget {
  const OfflineStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final String? text = switch (app.status) {
      SyncStatus.offline => 'غير متصل — الشغل بيتحفظ على الجهاز${app.pending > 0 ? ' (${app.pending} مستنية)' : ''}',
      SyncStatus.unpaired => 'الجهاز اتفصل من السيرفر — كلّم المدير',
      SyncStatus.error => 'السيرفر رد بخطأ — الشغل بيتحفظ على الجهاز',
      _ => null,
    };
    if (text == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: cOrange2,
      padding: const EdgeInsets.symmetric(horizontal: S.edge, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, size: 18, color: cOrange),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: cOrange),
            ),
          ),
        ],
      ),
    );
  }
}

/// Standard work screen: scanner, top bar, offline strip, body and an optional footer.
class WorkScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final Widget? footer;
  final void Function(String code)? onScan;
  final bool back;
  const WorkScaffold({super.key, required this.title, required this.body, this.footer, this.onScan, this.back = true});

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      appBar: topBar(context, title, back: back),
      body: Column(
        children: [
          const OfflineStrip(),
          Expanded(child: body),
        ],
      ),
      bottomNavigationBar: footer,
    );
    return onScan == null ? scaffold : ScanListener(onScan: onScan!, child: scaffold);
  }
}

enum ButtonKind { primary, secondary, danger, quiet }

class BigButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final ButtonKind kind;
  final double height;
  const BigButton(this.label, {super.key, this.icon, this.onPressed, this.kind = ButtonKind.primary, this.height = S.button});
  const BigButton.light(this.label, {super.key, this.icon, this.onPressed, this.height = S.button}) : kind = ButtonKind.secondary;
  const BigButton.danger(this.label, {super.key, this.icon, this.onPressed, this.height = S.button}) : kind = ButtonKind.danger;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, BorderSide side) = switch (kind) {
      ButtonKind.primary => (cPrimary, Colors.white, BorderSide.none),
      ButtonKind.secondary => (cSurface, cInk, const BorderSide(color: cLine, width: 1.5)),
      ButtonKind.danger => (cRed, Colors.white, BorderSide.none),
      ButtonKind.quiet => (cGray2, cInk, BorderSide.none),
    };
    return SizedBox(
      height: height,
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          disabledBackgroundColor: kind == ButtonKind.secondary ? cSurface : bg.withValues(alpha: .35),
          disabledForegroundColor: fg.withValues(alpha: .6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(S.radius), side: side),
          textStyle: T.button,
          padding: const EdgeInsets.symmetric(horizontal: S.m),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, size: 22), const SizedBox(width: 6)],
            Flexible(child: Text(label, textAlign: TextAlign.center, maxLines: 2)),
          ],
        ),
      ),
    );
  }
}

/// Square button at least 48 x 48 (quantity steps, edit, delete).
class IconBox extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color fg, bg;
  const IconBox(this.icon, {super.key, required this.label, this.onPressed, this.fg = cInk, this.bg = cGray2});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Material(
      color: onPressed == null ? cGray2.withValues(alpha: .5) : bg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: SizedBox(
          width: S.touch,
          height: S.touch,
          child: Icon(icon, size: 24, color: onPressed == null ? cMuted.withValues(alpha: .5) : fg),
        ),
      ),
    ),
  );
}

/// The one item row used by sale, count and receiving:
///   line 1: name ................ amount
///   line 2: details ............. controls
class ItemRow extends StatelessWidget {
  final String title;
  final String? amount;
  final Widget? details;
  final Widget? controls;
  final Widget? badge;
  final bool highlight;
  final Color? accent;
  final VoidCallback? onTap;
  const ItemRow({
    super.key,
    required this.title,
    this.amount,
    this.details,
    this.controls,
    this.badge,
    this.highlight = false,
    this.accent,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: S.rowGap),
      child: Material(
        color: highlight ? cGreen2 : cSurface,
        borderRadius: BorderRadius.circular(S.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(S.radius),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(S.radius),
              border: Border.all(color: highlight ? cGreen : (accent ?? cLine), width: highlight || accent != null ? 1.5 : 1),
            ),
            padding: const EdgeInsets.fromLTRB(S.m, S.s, S.m, S.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.item),
                    ),
                    if (badge != null) ...[const SizedBox(width: S.s), Flexible(child: badge!)],
                    if (amount != null) ...[const SizedBox(width: S.s), Text(amount!, textDirection: TextDirection.ltr, style: T.amount)],
                  ],
                ),
                if (details != null || controls != null)
                  Row(
                    children: [
                      Expanded(
                        child: DefaultTextStyle.merge(style: T.sub, child: details ?? const SizedBox()),
                      ),
                      ?controls,
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// − quantity + with 48 dp targets. The quantity opens the number pad.
class QtyStepper extends StatelessWidget {
  final String text;
  final VoidCallback? onMinus, onPlus, onTapQty;
  const QtyStepper({super.key, required this.text, this.onMinus, this.onPlus, this.onTapQty});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (onPlus != null || onMinus != null) IconBox(Icons.add, label: 'زيادة', onPressed: onPlus, fg: cPrimary, bg: cGreen2),
      Semantics(
        button: true,
        label: 'تعديل الكمية $text',
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTapQty,
          child: Container(
            constraints: const BoxConstraints(minWidth: 64, minHeight: S.touch),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              text,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, decoration: TextDecoration.underline),
            ),
          ),
        ),
      ),
      if (onPlus != null || onMinus != null) IconBox(Icons.remove, label: 'نقص', onPressed: onMinus),
    ],
  );
}

class CardBox extends StatelessWidget {
  final Widget child;
  final Color border;
  final Color? color;
  final EdgeInsets padding;
  const CardBox({super.key, required this.child, this.border = cLine, this.color, this.padding = const EdgeInsets.all(S.m)});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: S.s),
    padding: padding,
    decoration: BoxDecoration(
      color: color ?? cSurface,
      borderRadius: BorderRadius.circular(S.radius),
      border: Border.all(color: border),
    ),
    child: child,
  );
}

/// Status label: always text (and optionally an icon), never colour alone.
class Pill extends StatelessWidget {
  final String text;
  final Color fg, bg;
  final IconData? icon;
  const Pill(this.text, {super.key, this.fg = cMuted, this.bg = cGray2, this.icon});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 3)],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: T.pill.copyWith(color: fg),
          ),
        ),
      ],
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
      color: cSurface,
      border: Border(top: BorderSide(color: cLine)),
      boxShadow: [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, -2))],
    ),
    padding: EdgeInsets.fromLTRB(S.edge, S.s, S.edge, S.s + MediaQuery.of(context).padding.bottom),
    child: Column(mainAxisSize: MainAxisSize.min, children: children),
  );
}

/// Shown when a list is empty: what to do next.
class ScanPrompt extends StatelessWidget {
  final String title, sub;
  final VoidCallback onType, onSearch;
  const ScanPrompt({super.key, required this.title, required this.sub, required this.onType, required this.onSearch});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: S.l, horizontal: S.m),
        decoration: BoxDecoration(
          color: cSurface,
          borderRadius: BorderRadius.circular(S.radius),
          border: Border.all(color: const Color(0xFFA9BAB1), width: 1.5),
        ),
        child: Column(
          children: [
            const Icon(Icons.qr_code_scanner, size: 52, color: cHead),
            const SizedBox(height: S.xs),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: cHead),
            ),
            Text(sub, textAlign: TextAlign.center, style: T.sub),
          ],
        ),
      ),
      const SizedBox(height: S.s),
      _AltButtons(onType: onType, onSearch: onSearch),
    ],
  );
}

/// One-line reminder above a list that scanning keeps working, plus typed/name fallbacks.
class ScanBar extends StatelessWidget {
  final String text;
  final VoidCallback onType, onSearch;
  const ScanBar({super.key, required this.text, required this.onType, required this.onSearch});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: S.s),
    child: Row(
      children: [
        const Icon(Icons.qr_code_scanner, size: 22, color: cHead),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: T.subStrong)),
        _small(Icons.dialpad, 'رقم', onType),
        const SizedBox(width: S.xs),
        _small(Icons.search, 'اسم', onSearch),
      ],
    ),
  );

  Widget _small(IconData i, String t, VoidCallback f) => Material(
    color: cSurface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: cLine),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: f,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(i, size: 20),
              const SizedBox(width: 4),
              Text(t, style: T.label),
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
        child: BigButton.light('اكتب الرقم', icon: Icons.dialpad, onPressed: onType),
      ),
      const SizedBox(width: S.s),
      Expanded(
        child: BigButton.light('ابحث بالاسم', icon: Icons.search, onPressed: onSearch),
      ),
    ],
  );
}

/// Screen-level message with what the person can do next (empty, loading, error...).
class StateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? sub;
  final Widget? action;
  const StateMessage({super.key, required this.icon, required this.title, this.sub, this.action});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(S.l),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 44, color: cMuted),
        const SizedBox(height: S.s),
        Text(title, textAlign: TextAlign.center, style: T.heading),
        if (sub != null) Text(sub!, textAlign: TextAlign.center, style: T.sub),
        if (action != null) ...[const SizedBox(height: S.m), action!],
      ],
    ),
  );
}

/// "Saved on the device" vs "sent to the server", from the real state of the outbox.
class SendStatus extends StatefulWidget {
  final String outboxKey;
  const SendStatus({super.key, required this.outboxKey});
  @override
  State<SendStatus> createState() => _SendStatusState();
}

enum _Send { waiting, sent, rejected }

class _SendStatusState extends State<SendStatus> {
  _Send state = _Send.waiting;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context); // rebuilds after every sync
    () async {
      final rejected = (await app.db.rejectedOutbox()).any((r) => r['id'] == widget.outboxKey);
      final inBox = await app.db.inOutbox(widget.outboxKey);
      final s = rejected ? _Send.rejected : (inBox ? _Send.waiting : _Send.sent);
      if (mounted && s != state) setState(() => state = s);
    }();
  }

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String text, Color fg, Color bg) = switch (state) {
      _Send.rejected => (Icons.error_outline, 'السيرفر رفضها — افتح المزامنة', cRed, cRed2),
      _Send.sent => (Icons.cloud_done_outlined, W.sent, cGreen, cGreen2),
      _Send.waiting => (Icons.save_outlined, W.savedLocal, cOrange, cOrange2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: S.m, vertical: S.s),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(S.radius)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: 22),
          const SizedBox(width: S.s),
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- sheets ----------

Future<R?> _sheet<R>(BuildContext context, Widget child, {bool dismissible = true}) => showModalBottomSheet<R>(
  context: context,
  isScrollControlled: true,
  isDismissible: dismissible,
  enableDrag: dismissible,
  backgroundColor: cSurface,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
  builder: (_) => SafeArea(
    child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(S.m, S.m, S.m, S.m), child: child),
  ),
);

/// Bottom sheet with the app's standard look.
Future<R?> showAppSheet<R>(BuildContext context, Widget child) => _sheet<R>(context, child);

Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  Widget? body,
  required String yes,
  String no = W.back,
  bool danger = false,
}) async {
  final r = await _sheet<bool>(
    context,
    Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(danger ? Icons.warning_amber_rounded : Icons.help_outline, color: danger ? cRed : cHead),
            const SizedBox(width: S.s),
            Expanded(
              child: Text(title, style: T.heading.copyWith(fontSize: 20, color: danger ? cRed : cInk)),
            ),
          ],
        ),
        if (body != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: S.s),
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 17, color: cInk),
              child: body,
            ),
          ),
        const SizedBox(height: S.s),
        Builder(
          builder: (ctx) => Row(
            children: [
              Expanded(child: BigButton.light(no, onPressed: () => Navigator.pop(ctx, false))),
              const SizedBox(width: S.s),
              Expanded(
                child: BigButton(yes, kind: danger ? ButtonKind.danger : ButtonKind.primary, onPressed: () => Navigator.pop(ctx, true)),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Error message. [action] adds a second button (e.g. "search by name").
Future<String?> alertSheet(BuildContext context, {required String title, Widget? body, String? action}) => _sheet<String>(
  context,
  Builder(
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.error_outline, color: cRed),
            const SizedBox(width: S.s),
            Expanded(
              child: Text(title, style: T.heading.copyWith(fontSize: 20, color: cRed)),
            ),
          ],
        ),
        if (body != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: S.s),
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 17, color: cInk),
              child: body,
            ),
          ),
        const SizedBox(height: S.s),
        if (action != null)
          Row(
            children: [
              Expanded(child: BigButton.light('حسناً', onPressed: () => Navigator.pop(ctx))),
              const SizedBox(width: S.s),
              Expanded(child: BigButton(action, onPressed: () => Navigator.pop(ctx, action))),
            ],
          )
        else
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

/// Number pad for quantities. Returns null when cancelled.
/// [carton]: pieces per carton, shown under the unit choice.
/// [preview]: live line under the display, e.g. the line total in a sale.
Future<PadResult?> numberPad(
  BuildContext context, {
  required String title,
  String? hint,
  List<String> modes = const ['piece'],
  String? mode,
  int? initial,
  bool allowZero = false,
  bool barcode = false,
  int carton = 0,
  String? Function(int qtyMilli, String mode)? preview,
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
      carton: carton,
      preview: preview,
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
  final int carton;
  final String? Function(int qtyMilli, String mode)? preview;
  final String ok;
  const _NumberPad({
    required this.title,
    this.hint,
    required this.modes,
    required this.mode,
    this.initial,
    required this.allowZero,
    required this.barcode,
    this.carton = 0,
    this.preview,
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
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  final _field = TextEditingController();
  final _focus = FocusNode(debugLabel: 'pad-scanner');

  void _char(String ch) {
    final now = DateTime.now();
    if (now.difference(_kbLast) > const Duration(milliseconds: 1500)) _kb.clear();
    _kbLast = now;
    _kb.write(ch);
    if (RegExp(r'^[0-9.]$').hasMatch(ch)) _press(ch);
  }

  void _enter() {
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
  }

  // The built-in scanner (key events) and hardware keypads type straight into the pad.
  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    if (e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.numpadEnter ||
        e.logicalKey == LogicalKeyboardKey.tab) {
      _enter();
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace) {
      _press('back');
      return true;
    }
    final ch = e.character;
    if (ch != null && RegExp(r'^[0-9A-Za-z.\-]$').hasMatch(ch)) {
      _char(ch);
      return true;
    }
    return false;
  }

  // Scanners that inject text instead of key events.
  void _onField(String text) {
    if (text.isEmpty) return;
    _field.clear();
    for (final ch in text.split('')) {
      if (ch == '\n' || ch == '\r' || ch == '\t') {
        _enter();
        return;
      }
      if (RegExp(r'^[0-9A-Za-z.\-]$').hasMatch(ch)) _char(ch);
    }
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
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: Opacity(
            opacity: 0,
            child: ExcludeSemantics(
              child: TextField(
                key: const Key('pad-scanner-input'),
                controller: _field,
                focusNode: _focus,
                autofocus: true,
                keyboardType: TextInputType.none,
                showCursor: false,
                enableInteractiveSelection: false,
                onChanged: _onField,
                onSubmitted: (_) => _enter(),
              ),
            ),
          ),
        ),
        _body(context),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final kg = mode == 'kg';
    final keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', widget.barcode ? 'clear' : (kg ? '.' : 'clear'), '0', 'back'];
    final v = parseMilli(value);
    final preview = (v != null && v > 0 && widget.preview != null) ? widget.preview!(v, mode) : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.heading),
        if (widget.hint != null) Text(widget.hint!, style: T.sub),
        const SizedBox(height: S.s),
        if (widget.modes.length > 1) ...[
          Row(
            children: [
              for (final m in widget.modes)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: SizedBox(
                      height: S.touch,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: m == mode ? cPrimary : cSurface,
                          foregroundColor: m == mode ? Colors.white : cInk,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(color: m == mode ? cPrimary : cLine, width: 1.5),
                          ),
                          textStyle: T.button,
                        ),
                        // The check mark says which unit is chosen without relying on colour.
                        icon: m == mode ? const Icon(Icons.check, size: 20) : const SizedBox.shrink(),
                        onPressed: () => setState(() {
                          mode = m;
                          if (m != 'kg' && value.contains('.')) value = value.split('.')[0];
                        }),
                        label: Text(unitNames[m]!),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (widget.carton > 0)
            Padding(
              padding: const EdgeInsets.only(top: S.xs),
              child: Text('الكرتون = ${widget.carton} حبة', textAlign: TextAlign.center, style: T.sub),
            ),
          const SizedBox(height: S.s),
        ],
        Container(
          height: 58,
          margin: const EdgeInsets.only(bottom: S.xs),
          decoration: BoxDecoration(
            border: Border.all(color: cLine, width: 1.5),
            borderRadius: BorderRadius.circular(S.radius),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value.isEmpty ? (kg ? '0.000' : '0') : value,
                textDirection: TextDirection.ltr,
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: value.isEmpty ? const Color(0xFFB8C2BD) : cInk),
              ),
              if (!widget.barcode) ...[const SizedBox(width: S.s), Text(unitNames[mode]!, style: T.heading.copyWith(color: cMuted))],
            ],
          ),
        ),
        SizedBox(
          height: 22,
          child: Text(
            err ?? preview ?? (kg ? 'مثال: 1.250 كجم' : ''),
            textAlign: TextAlign.center,
            style: err != null ? const TextStyle(color: cRed, fontSize: 15, fontWeight: FontWeight.w800) : T.subStrong,
          ),
        ),
        const SizedBox(height: S.xs),
        Directionality(
          textDirection: TextDirection.ltr,
          child: GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 2.2,
            children: [
              for (final k in keys)
                Semantics(
                  button: true,
                  label: k == 'back' ? 'مسح رقم' : (k == 'clear' ? 'مسح الكل' : k),
                  child: Material(
                    color: cGray2,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _press(k),
                      child: Center(
                        child: k == 'back'
                            ? const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.backspace_outlined, size: 22),
                                  SizedBox(width: 4),
                                  Text('مسح', style: T.label),
                                ],
                              )
                            : Text(
                                k == 'clear' ? 'مسح الكل' : k,
                                style: TextStyle(fontSize: k.length > 1 ? 16 : 26, fontWeight: FontWeight.w800),
                              ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: S.s),
        Row(
          children: [
            Expanded(child: BigButton.light('إلغاء', onPressed: () => Navigator.pop(context))),
            const SizedBox(width: S.s),
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
          const Text('ابحث باسم الصنف', style: T.heading),
          const SizedBox(height: 10),
          TextField(
            autofocus: true,
            style: const TextStyle(fontSize: 18),
            decoration: InputDecoration(
              hintText: 'مثال: أرز، أو رقم الباركود',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              contentPadding: const EdgeInsets.all(14),
            ),
            onChanged: (q) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 250), () => _run(q));
            },
            // Scanning while this is open types the barcode here: pick that product directly.
            onSubmitted: (q) async {
              q = q.trim();
              if (q.isEmpty) return;
              final r = await widget.search(q);
              final hit = r.where((p) => p.barcode == q || p.barcode == '0$q' || '0${p.barcode}' == q).toList();
              if (!context.mounted) return;
              if (hit.length == 1) {
                Navigator.pop(context, hit.first);
              } else if (r.length == 1) {
                Navigator.pop(context, r.first);
              } else {
                setState(() => items = r);
              }
            },
          ),
          const SizedBox(height: 8),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text('لا يوجد صنف بالاسم ده.\nجرّب جزء من الاسم، أو امسح الباركود.', textAlign: TextAlign.center, style: T.sub),
                  )
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = items[i];
                      return ListTile(
                        minVerticalPadding: 8,
                        title: Text(p.name, maxLines: 2, style: T.item),
                        subtitle: Text(
                          '${p.barcode} · ${p.isKg ? 'بالكيلو' : (p.carton > 0 ? 'حبة / كرتون ${p.carton}' : 'بالحبة')}',
                          style: T.sub,
                        ),
                        trailing: Text('${money(p.price)}\n${p.isKg ? '/كجم' : '/حبة'}', textAlign: TextAlign.center, style: T.amount),
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
