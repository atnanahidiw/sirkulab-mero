import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'l10n/app_localizations.dart';
import 'services/locale_service.dart';
import 'services/model_service.dart';
import 'widgets/startup_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Force vertical orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Initialize FlutterGemma
  await FlutterGemma.initialize(
    // webStorageMode: WebStorageMode.cacheApi, // Optional for web
    maxDownloadRetries: 10,
  );

  final modelService = ModelService();
  final localeService = LocaleService();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ModelService>.value(value: modelService),
        ChangeNotifierProvider<LocaleService>.value(value: localeService),
      ],
      child: const MeroApp(),
    ),
  );
}

class MeroApp extends StatelessWidget {
  const MeroApp({super.key});

  @override
  Widget build(BuildContext context) {
    final localeService = Provider.of<LocaleService>(context);

    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      locale: localeService.locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: const StartupGate(),
      debugShowCheckedModeBanner: false,
    );
  }
}
