import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../pages/home_page.dart';
import '../services/model_boot_state.dart';
import '../services/model_service.dart';
import 'model_boot_splash.dart';

class StartupGate extends StatefulWidget {
  final Widget readyChild;
  final Duration splashDuration;

  const StartupGate({
    super.key,
    this.readyChild = const HomePage(),
    this.splashDuration = const Duration(seconds: 2),
  });

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  Timer? _timer;
  bool _showReadyChild = false;
  bool _delayScheduled = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ModelService>(
      builder: (context, modelService, _) {
        if (modelService.isInitialized) {
          if (!_delayScheduled && !_showReadyChild) {
            _delayScheduled = true;
            _timer?.cancel();
            _timer = Timer(widget.splashDuration, () {
              if (!mounted) {
                return;
              }
              setState(() {
                _showReadyChild = true;
              });
            });
          }

          if (_showReadyChild) {
            return widget.readyChild;
          }
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
