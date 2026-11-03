import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import '../util/feedback.dart';
import 'scope.dart';
import 'widgets.dart';

/// Staff pick their name, then type their PIN. Works without a network.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  List<Employee>? _staff;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await AppScope.read(context).db.activeEmployees();
    if (mounted) setState(() => _staff = list);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    // Reload the list when a sync brings new staff.
    if (app.status == SyncStatus.ok && _staff != null && _staff!.isEmpty) _load();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Row(
          children: [
            const Icon(Icons.diamond_outlined, size: 30),
            const SizedBox(width: 8),
            const Expanded(child: Text('تموين', style: T.pageTitle)),
            Text(app.deviceName ?? '', style: const TextStyle(fontSize: 16)),
          ],
        ),
      ),
      body: _staff == null
          ? const Center(child: CircularProgressIndicator())
          : _staff!.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('مفيش موظفين على الجهاز لسه.', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  const Text(
                    'أضف الموظفين من لوحة التحكم، وبعدين اضغط «تحديث».',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, color: cMuted),
                  ),
                  const SizedBox(height: 16),
                  BigButton(
                    'تحديث',
                    icon: Icons.sync,
                    onPressed: () async {
                      await app.sync(full: true);
                      _load();
                    },
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                await app.sync(full: true);
                await _load();
              },
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
                    child: Text('اضغط على اسمك', style: T.heading),
                  ),
                  for (final e in _staff!)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Material(
                        color: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: cLine, width: 2),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PinScreen(employee: e))),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 26,
                                  backgroundColor: cGreen2,
                                  child: Text(
                                    e.name.characters.first,
                                    style: const TextStyle(fontSize: 20, color: cGreen, fontWeight: FontWeight.w800),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(child: Text(e.name, style: T.heading)),
                                Text(e.roleName, style: const TextStyle(fontSize: 17, color: cMuted)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class PinScreen extends StatefulWidget {
  final Employee employee;
  const PinScreen({super.key, required this.employee});
  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String pin = '';
  bool busy = false;
  String? err;

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

  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    if (e.logicalKey == LogicalKeyboardKey.enter) {
      _submit();
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace) {
      _press('back');
      return true;
    }
    final ch = e.character;
    if (ch != null && RegExp(r'^\d$').hasMatch(ch)) {
      _press(ch);
      return true;
    }
    return false;
  }

  void _press(String k) {
    if (busy) return;
    setState(() {
      err = null;
      if (k == 'back') {
        if (pin.isNotEmpty) pin = pin.substring(0, pin.length - 1);
      } else if (pin.length < 6) {
        pin += k;
      }
    });
  }

  Future<void> _submit() async {
    if (pin.length < 4 || busy) {
      setState(() => err = 'الرقم السري من 4 إلى 6 أرقام');
      return;
    }
    setState(() => busy = true);
    final app = AppScope.read(context);
    final ok = await app.login(widget.employee, pin);
    if (!mounted) return;
    if (ok) {
      beepOk();
      Navigator.of(context).pop();
    } else {
      beepError();
      setState(() {
        busy = false;
        pin = '';
        err = 'الرقم السري غلط';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', 'back'];
    return Scaffold(
      appBar: topBar(context, widget.employee.name),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('اكتب رقمك السري', textAlign: TextAlign.center, style: T.heading),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                6,
                (i) => Container(
                  width: 22,
                  height: 22,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < pin.length ? cHead : Colors.white,
                    border: Border.all(color: i < 4 || i < pin.length ? cHead : cLine, width: 2),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 44,
              child: Center(
                child: busy
                    ? const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3))
                    : Text(
                        err ?? '',
                        style: const TextStyle(color: cRed, fontSize: 20, fontWeight: FontWeight.w800),
                      ),
              ),
            ),
            Expanded(
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: GridView.count(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.6,
                  physics: const NeverScrollableScrollPhysics(),
                  children: keys
                      .map(
                        (k) => k.isEmpty
                            ? const SizedBox()
                            : Material(
                                color: cGray2,
                                borderRadius: BorderRadius.circular(14),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () => _press(k),
                                  child: Center(
                                    child: k == 'back'
                                        ? const Icon(Icons.backspace_outlined, size: 30)
                                        : Text(k, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                                  ),
                                ),
                              ),
                      )
                      .toList(),
                ),
              ),
            ),
            BigButton('دخول', icon: Icons.login, onPressed: busy ? null : _submit),
          ],
        ),
      ),
    );
  }
}
