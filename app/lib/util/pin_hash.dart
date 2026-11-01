import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PBKDF2-HMAC-SHA256, single 32-byte block. Must match server/app/security.py.
const pinIterations = 20000;

String hashPin(String pin, String salt, {int iterations = pinIterations}) {
  final hmac = Hmac(sha256, utf8.encode(pin));
  final block = Uint8List.fromList([...utf8.encode(salt), 0, 0, 0, 1]);
  var u = hmac.convert(block).bytes;
  final out = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Arguments as a list so it can run through compute() off the UI thread.
bool verifyPinArgs(List<String> a) => hashPin(a[0], a[1]) == a[2];
