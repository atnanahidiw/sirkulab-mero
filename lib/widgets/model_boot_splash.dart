import 'dart:io';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../services/model_boot_state.dart';
import '../services/model_download_notification_service.dart';

typedef DownloadCallback = void Function({
  String? customUrl,
  bool preferDownloadsFolder,
});

class ModelBootSplash extends StatelessWidget {
  final String status;
  final String? error;
  final double? progress;
  final bool isLoading;
  final ModelBootPhase phase;
  final String? modelSize;
  final String? downloadFilePath;
  final DownloadCallback? onConfirmDownload;
  final Future<void> Function()? onLoadExistingModel;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  const ModelBootSplash({
    super.key,
    required this.status,
    required this.error,
    required this.progress,
    required this.isLoading,
    required this.phase,
    this.modelSize,
    this.downloadFilePath,
    this.onConfirmDownload,
    this.onLoadExistingModel,
    this.onRetry,
    this.onCancel,
  });

  String _phaseLabel(AppLocalizations l10n) {
    return switch (phase) {
      ModelBootPhase.idle => l10n.bootPhasePreparing,
      ModelBootPhase.checking => l10n.bootPhaseChecking,
      ModelBootPhase.needsDownload => l10n.bootPhaseNeedsDownload,
      ModelBootPhase.starting => l10n.bootPhaseStarting,
      ModelBootPhase.downloading => l10n.bootPhaseDownloading,
      ModelBootPhase.resuming => l10n.bootPhaseResuming,
      ModelBootPhase.paused => l10n.bootPhasePaused,
      ModelBootPhase.canceled => l10n.bootPhaseCanceled,
      ModelBootPhase.installing => l10n.bootPhaseInstalling,
      ModelBootPhase.failed => l10n.bootPhaseFailed,
      ModelBootPhase.ready => l10n.bootPhaseReady,
      ModelBootPhase.analyzing => l10n.bootPhaseAnalyzing,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final percent =
        progress == null ? null : (progress!.clamp(0.0, 1.0) * 100).round();

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Stack(
          children: [
            // Center: Brand mark and title (hidden when showing download dialog)
            if (phase != ModelBootPhase.needsDownload)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _BrandMark(colorScheme: colorScheme),
                    const SizedBox(height: 24),
                    Text(
                      l10n.appTitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.displaySmall?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: AutoSizeText(
                        l10n.appSubtitle,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        minFontSize: 10,
                        stepGranularity: 0.5,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colorScheme.primary,
                          letterSpacing: 0.3,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: AutoSizeText(
                        l10n.appTagline,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        minFontSize: 10,
                        stepGranularity: 0.5,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                          height: 1.2,
                        ),
                      ),
                    ),
                    // Balance padding for visual centering
                    const SizedBox(height: 88),
                  ],
                ),
              ),
            // Center: Download confirmation dialog
            if (phase == ModelBootPhase.needsDownload)
              Center(
                child: _DownloadConfirmationCard(
                  modelSize: modelSize,
                  downloadFilePath: downloadFilePath,
                  onDownload: onConfirmDownload ??
                      (
                          {String? customUrl,
                          bool preferDownloadsFolder = false}) {},
                  onLoadExistingModel: onLoadExistingModel,
                  onCancel: onCancel,
                ),
              ),
            // Bottom: State indicator (hidden when showing download dialog)
            if (phase != ModelBootPhase.needsDownload)
              Positioned(
                bottom: 48,
                left: 32,
                right: 32,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, animation) {
                    return ScaleTransition(
                      scale: animation,
                      child: FadeTransition(
                        opacity: animation,
                        child: child,
                      ),
                    );
                  },
                  child: _buildStateIndicator(context, colorScheme, percent, l10n),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStateIndicator(
      BuildContext context, ColorScheme scheme, int? percent, AppLocalizations l10n) {
    // Ready state
    if (phase == ModelBootPhase.ready) {
      return Center(
        key: const ValueKey('ready'),
        child: Text(
          l10n.commonReady,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
        ),
      );
    }

    // Error/failed state
    if (error != null) {
      final errorLabel = phase == ModelBootPhase.canceled
          ? l10n.bootDownloadCanceled
          : l10n.bootSetupFailed;
      return Center(
        key: const ValueKey('error'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              errorLabel,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            if (onRetry != null)
              FilledButton.tonal(
                onPressed: onRetry,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.refresh, size: 18),
                    const SizedBox(width: 8),
                    Text(phase == ModelBootPhase.paused ? l10n.bootResume : l10n.commonRetry),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    // Active downloading state
    final progressValue = progress ?? 0.0;
    final displayPercent = percent ?? (progressValue * 100).round();
    return Center(
      key: const ValueKey('downloading'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Rounded pill progress bar
          Container(
            height: 8,
            width: 200,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progressValue.clamp(0.0, 1.0),
                child: Container(
                  height: 8,
                  color: scheme.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${_phaseLabel(l10n)}… $displayPercent%',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  final ColorScheme colorScheme;

  const _BrandMark({required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Outer circle — surface container
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colorScheme.surfaceContainerHigh,
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withValues(alpha: 0.18),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
        ),
        // Inner circle — gradient fill
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colorScheme.primary,
                colorScheme.primaryContainer,
              ],
            ),
          ),
          child: Icon(
            Icons.eco_outlined,
            size: 36,
            color: colorScheme.onPrimary,
          ),
        ),
      ],
    );
  }
}

class _DownloadConfirmationCard extends StatefulWidget {
  final String? modelSize;
  final String? downloadFilePath;
  final DownloadCallback onDownload;
  final Future<void> Function()? onLoadExistingModel;
  final VoidCallback? onCancel;

  const _DownloadConfirmationCard({
    this.modelSize,
    this.downloadFilePath,
    required this.onDownload,
    this.onLoadExistingModel,
    this.onCancel,
  });

  @override
  State<_DownloadConfirmationCard> createState() =>
      _DownloadConfirmationCardState();
}

class _DownloadConfirmationCardState extends State<_DownloadConfirmationCard>
    with WidgetsBindingObserver {
  bool _showAdvanced = false;
  bool _storageGranted = false;
  final _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isAndroid) {
      _checkStoragePermission();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _isAndroid) {
      _checkStoragePermission();
      _maybeLoadExistingDownloadedModel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _checkStoragePermission() async {
    final granted = await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted;
    if (!mounted) return;
    setState(() => _storageGranted = granted);
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  Future<void> _requestStoragePermission() async {
    // manageExternalStorage.request() on Android 11+ opens the dedicated
    // "Allow access to manage all files" page directly instead of generic app settings.
    // On older Android it shows the standard permission dialog.
    var status = await Permission.manageExternalStorage.request();
    if (!status.isGranted) {
      status = await Permission.storage.request();
    }
    if (!mounted) return;
    final granted = status.isGranted ||
        await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted;
    setState(() => _storageGranted = granted);
    if (!granted) {
      return;
    }

    if (!mounted) return;
    await _maybeLoadExistingDownloadedModel();
  }

  Future<bool> _hasStoragePermission() async {
    return await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted;
  }

  Future<void> _maybeLoadExistingDownloadedModel() async {
    if (!mounted || widget.onLoadExistingModel == null) {
      return;
    }

    final filePath = widget.downloadFilePath;
    if (filePath == null || !await File(filePath).exists()) {
      return;
    }

    if (!await _hasStoragePermission()) {
      return;
    }

    await widget.onLoadExistingModel!();
  }

  Future<void> _handleDownload() async {
    if (mounted) {
      await ModelDownloadNotificationService.requestPermission(context);
    }

    final customUrl = _urlController.text.trim();
    widget.onDownload(
      customUrl: customUrl.isNotEmpty ? customUrl : null,
      preferDownloadsFolder: Platform.isAndroid,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;

    final bool needsPermission = _isAndroid && !_storageGranted;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_download_outlined,
                size: 48,
                color: colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.bootPhaseNeedsDownload,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Column(
                children: [
                  Text(
                    l10n.bootIdentifySpeciesModel,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    l10n.bootNeedsToBeDownloaded(widget.modelSize != null ? ' (${widget.modelSize})' : ''),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.wifi_outlined,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.bootWifiWarning,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_showAdvanced ? l10n.bootHideAdvanced : l10n.bootAdvanced),
                    Icon(
                      _showAdvanced ? Icons.expand_less : Icons.expand_more,
                    ),
                  ],
                ),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    labelText: l10n.bootCustomModelUrl,
                    hintText: 'https://...',
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 16),
              ],
              if (needsPermission) ...[
                FilledButton.icon(
                  onPressed: _requestStoragePermission,
                  icon: const Icon(Icons.lock_open_outlined),
                  label: Text(l10n.bootGrantPermission),
                ),
              ] else
                FilledButton.icon(
                  onPressed: _handleDownload,
                  icon: const Icon(Icons.download),
                  label: Text(l10n.bootDownloadModel),
                ),
              if (widget.onCancel != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: widget.onCancel,
                  child: Text(l10n.commonCancel),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
