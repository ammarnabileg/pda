import 'package:flutter/services.dart';

const _channel = MethodChannel('tamween/beep');

Future<void> beepOk() async {
  HapticFeedback.lightImpact();
  try {
    await _channel.invokeMethod('ok');
  } catch (_) {}
}

Future<void> beepError() async {
  HapticFeedback.vibrate();
  try {
    await _channel.invokeMethod('error');
  } catch (_) {}
  await Future.delayed(const Duration(milliseconds: 180));
  HapticFeedback.vibrate();
}
