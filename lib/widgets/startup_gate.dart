import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../pages/home_page.dart';
import '../services/model_boot_state.dart';
import '../services/model_service.dart';
import 'model_boot_splash.dart';

class StartupGate extends StatelessWidget {
  final Widget readyChild;

  const StartupGate({
    super.key,
    this.readyChild = const HomePage(),
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<ModelService>(
      builder: (context, modelService, _) {
        if (modelService.isModelLoaded) {
          return readyChild;
        }

        return ModelBootSplash(
          status: modelService.status,
          error: modelService.error,
          progress: modelService.downloadProgress,
          isLoading: modelService.isLoading,
          phase: modelService.phase,
          modelSize: modelService.pendingModelSize,
          downloadFilePath: modelService.downloadFilePath,
          onConfirmDownload: modelService.phase == ModelBootPhase.needsDownload
              ? ({String? customUrl, bool preferDownloadsFolder = false}) =>
                  modelService.confirmDownload(
                    customUrl: customUrl,
                    preferDownloadsFolder: preferDownloadsFolder,
                  )
              : null,
          onLoadExistingModel: () =>
              modelService.downloadModel(onProgress: (_) {}),
          onRetry: switch (modelService.phase) {
            ModelBootPhase.paused => () => modelService.resumeDownload(),
            ModelBootPhase.canceled => () => modelService.retryInitialization(),
            _ when modelService.error != null => () =>
                modelService.retryInitialization(),
            _ => null,
          },
          onCancel: modelService.phase == ModelBootPhase.ready ||
                  modelService.phase == ModelBootPhase.idle ||
                  modelService.phase == ModelBootPhase.canceled ||
                  modelService.phase == ModelBootPhase.needsDownload
              ? null
              : () => modelService.cancelDownload(),
        );
      },
    );
  }
}
