import 'package:flutter/material.dart';

import 'scope.dart';
import 'widgets.dart';

/// First run: connect the device to the co-op server with a code from the dashboard.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _server = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    app.db.get('last_server').then((v) {
      if (v != null && mounted && _server.text.isEmpty) _server.text = v.replaceFirst('http://', '');
    });
  }

  Future<void> _pair() async {
    if (_server.text.trim().isEmpty || _code.text.trim().length < 6) {
      setState(() => _error = 'اكتب عنوان السيرفر وكود الربط (6 أرقام)');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = AppScope.read(context);
    await app.db.set('last_server', _server.text.trim());
    final err = await app.pair(_server.text, _code.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.all(16),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: topBar(context, 'ربط الجهاز', back: false),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('الجهاز ده لسه مش مربوط بسيرفر الجمعية.',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        const Text('المدير يفتح لوحة التحكم ← الأجهزة ← «إضافة جهاز»، ويديك العنوان والكود.',
            style: TextStyle(fontSize: 18, color: cMuted)),
        const SizedBox(height: 18),
        const Text('عنوان السيرفر', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        TextField(
          controller: _server,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textDirection: TextDirection.ltr,
          style: const TextStyle(fontSize: 22),
          decoration: _dec('مثال: 192.168.1.20'),
        ),
        const SizedBox(height: 14),
        const Text('كود الربط', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          textDirection: TextDirection.ltr,
          maxLength: 6,
          style: const TextStyle(fontSize: 30, letterSpacing: 8, fontWeight: FontWeight.w800),
          decoration: _dec('000000'),
        ),
        if (_error != null)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(color: cRed2, borderRadius: BorderRadius.circular(12)),
            child: Text(_error!, style: const TextStyle(color: cRed, fontSize: 18, fontWeight: FontWeight.w700)),
          ),
        BigButton(_busy ? 'جاري الربط…' : 'ربط الجهاز', icon: Icons.link, onPressed: _busy ? null : _pair),
      ]),
    );
  }
}
