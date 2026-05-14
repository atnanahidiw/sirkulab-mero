import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import '../core/navigation/app_page_route.dart';
import '../l10n/app_localizations.dart';
import '../services/model_service.dart';
import '../services/permission_service.dart';
import 'analyzing_page.dart';
import 'result_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  CameraController? _controller;
  late List<CameraDescription> _cameras;
  bool _isCameraReady = false;
  bool _isProcessing = false;
  bool _shouldCameraBeRunning = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    if (!_shouldCameraBeRunning) return;
    final currentContext = context;

    try {
      if (_controller != null && _controller!.value.isInitialized) {
        await _controller!.dispose();
        _controller = null;
      }

      await Future.delayed(const Duration(milliseconds: 100));

      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (currentContext.mounted) {
          final l10n = AppLocalizations.of(currentContext)!;
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(content: Text(l10n.homeNoCameras)),
          );
        }
        return;
      }

      _controller = CameraController(
        _cameras[0],
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _controller!.initialize();
      await _controller!.lockCaptureOrientation(DeviceOrientation.portraitUp);
      setState(() {
        _isCameraReady = true;
      });
    } catch (e) {
      debugPrint('Camera initialization error: $e');
      if (currentContext.mounted) {
        final l10n = AppLocalizations.of(currentContext)!;
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(content: Text(l10n.homeCameraInitError(e.toString()))),
        );
      }
      setState(() {
        _isCameraReady = false;
      });
    }
  }

  Future<bool> _checkAndRequestCameraPermission() async {
    final hasPermission = await PermissionService.hasCameraPermission();
    if (hasPermission) return true;

    final isPermanentlyDenied =
        await PermissionService.isPermissionPermanentlyDenied(Permission.camera);

    if (!mounted) return false;

    final l10n = AppLocalizations.of(context)!;

    if (isPermanentlyDenied) {
      final shouldOpenSettings = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.homeCameraPermissionRequired),
          content: Text(
            '${PermissionService.getPermissionRationale('camera')}\n\n'
            '${l10n.homeCameraPermissionDeniedPermanently}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.homeOpenSettings),
            ),
          ],
        ),
      );

      if (shouldOpenSettings == true) {
        await PermissionService.openPermissionSettings();
      }
      return false;
    }

    final shouldRequest = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.homeCameraAccess),
        content: Text(PermissionService.getPermissionRationale('camera')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.homeNotNow),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.homeAllow),
          ),
        ],
      ),
    );

    if (shouldRequest != true) return false;

    final result = await PermissionService.requestCameraPermission();
    return result.isGranted;
  }

  Future<void> _takePhoto() async {
    final currentContext = context;
    final modelService =
        Provider.of<ModelService>(currentContext, listen: false);

    final hasCameraPermission = await _checkAndRequestCameraPermission();
    if (!hasCameraPermission) {
      if (currentContext.mounted) {
        final l10n = AppLocalizations.of(currentContext)!;
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(
              content: Text(l10n.homeCameraPermissionRequiredToTakePhotos)),
        );
      }
      return;
    }

    if (_controller == null ||
        !_controller!.value.isInitialized ||
        _isProcessing) {
      return;
    }

    if (!modelService.isModelLoaded) {
      if (currentContext.mounted) {
        final l10n = AppLocalizations.of(currentContext)!;
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(content: Text(l10n.homeDownloadModelFirst)),
        );
      }
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      XFile image;
      try {
        image = await _controller!.takePicture();
      } catch (cameraError) {
        debugPrint('Camera error: $cameraError');
        if (currentContext.mounted) {
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(content: Text('Camera error: $cameraError')),
          );
        }
        return;
      }

      Uint8List bytes;
      try {
        bytes = await image.readAsBytes();
      } catch (readError) {
        debugPrint('Read error: $readError');
        if (currentContext.mounted) {
          final l10n = AppLocalizations.of(currentContext)!;
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(content: Text(l10n.homeFailedToReadImage(readError.toString()))),
          );
        }
        return;
      }

      if (!currentContext.mounted) return;

      // Set flag to false so lifecycle changes don't restart it
      _shouldCameraBeRunning = false;

      // Navigate first for a smoother transition
      final navigationFuture = Navigator.push(
        currentContext,
        AppPageRoute.fadeScale((_) => AnalyzingPage(rawImageBytes: bytes)),
      );

      // Then turn off camera to free up RAM for the AI process
      // Giving it a bit more time to ensure the transition is well underway
      Future.delayed(const Duration(milliseconds: 250), () async {
        if (_controller != null) {
          if (mounted) {
            setState(() {
              _isCameraReady = false;
            });
          }
          // Ensure the widget tree has updated before disposal
          await Future.delayed(const Duration(milliseconds: 100));
          await _controller?.dispose();
          _controller = null;
          debugPrint('Camera disposed after navigation');
        }
      });

      // Navigate to analyzing page and WAIT for results
      final analysisResult = await navigationFuture;

      // If analysis succeeded, navigate to ResultPage and WAIT again
      if (analysisResult is Map<String, dynamic> && currentContext.mounted) {
        await Navigator.push(
          currentContext,
          AppPageRoute.slideUp(
            (_) => ResultPage(
              imageBytes: analysisResult['imageBytes'],
              additionalImages: analysisResult['additionalImages'],
              analysisResult: analysisResult['analysisResult'],
              preloadedSpecies: analysisResult['preloadedSpecies'],
            ),
          ),
        );
      }

      // Only now, re-enable and re-initialize camera
      _shouldCameraBeRunning = true;
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted) {
          _initializeCamera();
        }
      });
    } catch (e) {
      if (currentContext.mounted) {
        final l10n = AppLocalizations.of(currentContext)!;
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(content: Text(l10n.homeFailedToAnalyzeImage(e.toString()))),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Widget _buildCameraPreview(AppLocalizations l10n) {
    if (_isCameraReady &&
        _controller != null &&
        _controller!.value.isInitialized) {
      try {
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: _controller!.value.previewSize!.height,
              height: _controller!.value.previewSize!.width,
              child: CameraPreview(_controller!),
            ),
          ),
        );
      } catch (e) {
        debugPrint('Camera preview error: $e');
        return _buildCameraErrorState(l10n);
      }
    } else {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
  }

  Widget _buildCameraErrorState(AppLocalizations l10n) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.camera_alt, color: Colors.white54, size: 64),
            const SizedBox(height: 16),
            Text(
              l10n.homeCameraUnavailable,
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _initializeCamera,
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        cameraController.dispose();
        setState(() => _isCameraReady = false);
        break;
      case AppLifecycleState.resumed:
        if (_shouldCameraBeRunning) {
          _initializeCamera();
        }
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    // Dispose camera controller and cancel any pending operations
    _controller?.dispose();
    _controller = null;
    _isCameraReady = false;

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final modelService = Provider.of<ModelService>(context);
    final topPadding = MediaQuery.of(context).padding.top;
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Full-screen camera
          Positioned.fill(
            child: _isCameraReady
                ? _buildCameraPreview(l10n)
                : _buildCameraErrorState(l10n),
          ),

          // Top gradient overlay — status chip + settings button
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, topPadding + 12, 8, 20),
                child: Row(
                  children: [
                    _ModelStatusChip(
                      modelService: modelService,
                      colorScheme: colorScheme,
                      textTheme: textTheme,
                      l10n: l10n,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined,
                          color: Colors.white),
                      onPressed: () => Navigator.push(
                        context,
                        AppPageRoute.slideRight((_) => const SettingsPage()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Model download status overlay
          if (modelService.status.isNotEmpty && !modelService.isModelLoaded)
            Positioned(
              top: topPadding + 80,
              left: 16,
              right: 16,
              child: _ModelStatusCard(
                modelService: modelService,
                colorScheme: colorScheme,
                textTheme: textTheme,
                l10n: l10n,
                onDownload: _downloadModel,
              ),
            ),

          // Bottom gradient overlay — capture FAB
          if (_isCameraReady)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.65),
                      Colors.transparent,
                    ],
                  ),
                ),
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 32,
                  top: 40,
                ),
                child: Center(
                  child: _ShutterButton(
                    isProcessing: _isProcessing,
                    isEnabled: !_isProcessing && modelService.isModelLoaded,
                    onPressed: _takePhoto,
                    primaryColor: colorScheme.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _downloadModel() async {
    final currentContext = context;
    final modelService =
        Provider.of<ModelService>(currentContext, listen: false);

    if (modelService.isLoading || modelService.isModelLoaded) return;

    try {
      await modelService.downloadModel(onProgress: (_) {});
    } catch (e) {
      if (currentContext.mounted) {
        final l10n = AppLocalizations.of(currentContext)!;
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(content: Text(l10n.homeFailedToAnalyzeImage(e.toString()))),
        );
      }
    }
  }
}

class _ModelStatusChip extends StatelessWidget {
  final ModelService modelService;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final AppLocalizations l10n;

  const _ModelStatusChip({
    required this.modelService,
    required this.colorScheme,
    required this.textTheme,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final isReady = modelService.isModelLoaded;
    final isError = modelService.error != null;
    final isLoading = modelService.isLoading;

    Widget icon;
    String label;

    if (isReady) {
      icon = Icon(Icons.check_circle_outline,
          size: 16, color: colorScheme.onPrimaryContainer);
      label = l10n.homeModelStatusReady;
    } else if (isError) {
      icon = Icon(Icons.error_outline, size: 16, color: colorScheme.error);
      label = l10n.homeModelStatusError;
    } else if (isLoading) {
      final percent = _extractPercent(modelService.status);
      icon = SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: percent != null ? percent / 100 : null,
          color: colorScheme.onPrimaryContainer,
        ),
      );
      label = percent != null ? '$percent%' : l10n.homeModelStatusLoading;
    } else {
      icon = Icon(Icons.download_outlined,
          size: 16, color: colorScheme.onPrimaryContainer);
      label = l10n.homeModelStatusTapToDownload;
    }

    return GestureDetector(
      onTap: isReady
          ? null
          : () {
              final modelService =
                  Provider.of<ModelService>(context, listen: false);
              if (!modelService.isLoading) {
                modelService.downloadModel(onProgress: (_) {});
              }
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 6),
            Text(
              label,
              style: textTheme.labelMedium?.copyWith(
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  int? _extractPercent(String status) {
    final match = RegExp(r'(\d+)%').firstMatch(status);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }
}

class _ModelStatusCard extends StatelessWidget {
  final ModelService modelService;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final AppLocalizations l10n;
  final VoidCallback onDownload;

  const _ModelStatusCard({
    required this.modelService,
    required this.colorScheme,
    required this.textTheme,
    required this.l10n,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.homeAiModel,
            style: textTheme.labelLarge?.copyWith(color: colorScheme.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            modelService.status,
            style: textTheme.bodySmall
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          if (modelService.error != null) ...[
            const SizedBox(height: 4),
            Text(
              modelService.error!,
              style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
            ),
          ],
          if (!modelService.isModelLoaded && !modelService.isLoading) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.download, size: 16),
              label: Text(l10n.homeDownloadModelWithButton),
            ),
          ],
        ],
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool isProcessing;
  final bool isEnabled;
  final VoidCallback onPressed;
  final Color primaryColor;

  const _ShutterButton({
    required this.isProcessing,
    required this.isEnabled,
    required this.onPressed,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isEnabled ? onPressed : null,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: isEnabled ? 0.8 : 0.3),
            width: 3,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isEnabled
                  ? primaryColor
                  : primaryColor.withValues(alpha: 0.4),
            ),
            child: isProcessing
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
