import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/app_state.dart';
import 'data/db.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';
import 'ui/scope.dart';
import 'ui/setup_screen.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final app = AppState(await LocalDb.open());
  await app.load();
  runApp(TamweenApp(app: app));
}

class TamweenApp extends StatelessWidget {
  final AppState app;
  const TamweenApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      notifier: app,
      child: MaterialApp(
        title: 'تموين',
        debugShowCheckedModeBanner: false,
        theme: appTheme(),
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          // Keep the large sizes we designed even if the device font scale is odd.
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.0)),
          child: child!,
        ),
        home: const Root(),
      ),
    );
  }
}

/// Chooses the first screen: pair the device, then log in, then work.
class Root extends StatelessWidget {
  const Root({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (!app.paired) return const SetupScreen();
    if (app.employee == null) return const LoginScreen();
    return const HomeScreen();
  }
}
