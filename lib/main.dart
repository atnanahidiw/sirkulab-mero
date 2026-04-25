import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:provider/provider.dart';

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
    PictureThatApp(modelService: modelService),
  );
}

class PictureThatApp extends StatelessWidget {
  final ModelService modelService;

  const PictureThatApp({
    super.key,
    required this.modelService,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ModelService>.value(
      value: modelService,
      child: MaterialApp(
        title: 'Picture That - Endangered Species Identifier',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.green,
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.green,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const StartupGate(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
