import 'package:flutter/material.dart';

/// The app's design system. Every size, colour and text style used by the screens
/// lives here, so the whole app can be tuned on the real device from one place.
///
/// Sizes are a first proposal for a 5" PDA (Honeywell EDA52, 360 x 640 dp) and are
/// meant to be adjusted after staff try it.

// ---------- colours ----------
const cHead = Color(0xFF123F37); // brand: app bar
const cPrimary = Color(0xFF0A6B3D); // main actions
const cBg = Color(0xFFF1F3F2); // neutral background
const cSurface = Colors.white;
const cInk = Color(0xFF15201B);
const cMuted = Color(0xFF55625C);
const cLine = Color(0xFFDDE3E0);
const cGray2 = Color(0xFFEEF2F0);

// Meanings: always shown with text or an icon too, never colour alone.
const cGreen = Color(0xFF0A6B3D); // success / matches
const cGreen2 = Color(0xFFE3F3EA);
const cRed = Color(0xFFB42318); // error / danger
const cRed2 = Color(0xFFFDECEB);
const cOrange = Color(0xFF9A5200); // warning / short
const cOrange2 = Color(0xFFFFF1DE);
const cBlue = Color(0xFF1D4FD8); // information / extra
const cBlue2 = Color(0xFFE7EEFD);

// ---------- spacing and sizes ----------
class S {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const edge = 10.0; // screen side padding
  static const rowGap = 6.0; // between item rows
  static const radius = 12.0;
  static const button = 50.0; // main action height
  static const touch = 48.0; // minimum touch target
  static const appBar = 56.0;
}

// ---------- text ----------
class T {
  static const pageTitle = TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white);
  static const heading = TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: cInk);
  static const item = TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: cInk, height: 1.25);
  static const amount = TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: cInk);
  static const sub = TextStyle(fontSize: 14, color: cMuted, height: 1.3);
  static const subStrong = TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: cInk);
  static const label = TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: cInk);
  static const button = TextStyle(fontSize: 18, fontWeight: FontWeight.w800);
  static const total = TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: cInk);
  static const bigPrice = TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: cPrimary);
  static const pill = TextStyle(fontSize: 13, fontWeight: FontWeight.w800);
}

// ---------- words used the same way everywhere ----------
class W {
  static const sync = 'مزامنة';
  static const syncNow = 'مزامنة الآن';
  static const savedLocal = 'محفوظ على الجهاز، مستني المزامنة';
  static const sent = 'اتبعت للسيرفر';
  static const back = 'رجوع';
  static const switchUser = 'تغيير الموظف';
  static const currency = 'د.ك';
}

ThemeData appTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: cPrimary, primary: cPrimary, surface: cSurface),
    scaffoldBackgroundColor: cBg,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: cInk, displayColor: cInk),
    appBarTheme: const AppBarTheme(backgroundColor: cHead, foregroundColor: Colors.white, toolbarHeight: S.appBar, elevation: 0),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
