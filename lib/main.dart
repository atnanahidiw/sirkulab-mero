import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_theme.dart';
import 'services/model_service.dart';
import 'widgets/startup_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables
  await dotenv.load(fileName: '.env');

  // Initialize FlutterGemma
  await FlutterGemma.initialize(
    // webStorageMode: WebStorageMode.cacheApi, // Optional for web
    huggingFaceToken: dotenv.env['HUGGINGFACE_TOKEN'],
    maxDownloadRetries: 10,
  );

  final modelService = ModelService();

  runApp(
    MeroApp(modelService: modelService),
  );
}

class MeroApp extends StatelessWidget {
  final ModelService modelService;

  const MeroApp({
    super.key,
    required this.modelService,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ModelService>.value(
      value: modelService,
      child: MaterialApp(
        title: 'Mero - Empowering the Guardians of Tomorrow',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        home: const StartupGate(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
