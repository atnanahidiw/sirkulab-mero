import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

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
  final DownloadCallback? onConfirmDownload;
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
    this.onConfirmDownload,
    this.onRetry,
    this.onCancel,
  });

  String _phaseLabel() {
    return switch (phase) {
      ModelBootPhase.idle => 'Preparing',
      ModelBootPhase.checking => 'Checking',
      ModelBootPhase.needsDownload => 'Download Required',
      ModelBootPhase.starting => 'Starting download',
      ModelBootPhase.downloading => 'Downloading',
      ModelBootPhase.resuming => 'Resuming',
      ModelBootPhase.paused => 'Paused',
      ModelBootPhase.canceled => 'Canceled',
      ModelBootPhase.installing => 'Installing',
      ModelBootPhase.failed => 'Needs attention',
      ModelBootPhase.ready => 'Ready',
      ModelBootPhase.analyzing => 'Working',
    };
  }

  String _phaseSubtitle() {
    return switch (phase) {
      ModelBootPhase.idle => 'Checking the model setup.',
      ModelBootPhase.checking =>
        'Looking for an existing model before we download anything.',
      ModelBootPhase.needsDownload =>
        'A machine learning model is needed to identify species.',
      ModelBootPhase.starting => 'Getting the download ready.',
      ModelBootPhase.downloading =>
        'Downloading the model in the background.',
      ModelBootPhase.resuming => '',
      ModelBootPhase.paused => 'The download is paused. You can resume it.',
      ModelBootPhase.canceled =>
        'The download was canceled. Start it again when you are ready.',
      ModelBootPhase.installing => 'Finishing local setup.',
      ModelBootPhase.failed => 'The download failed. You can try again here.',
      ModelBootPhase.ready => 'The model is ready and the app will open next.',
      ModelBootPhase.analyzing => 'Processing an image with the local model.',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
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
                      'Picture That',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.displaySmall?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Gotta Snap Them All!',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colorScheme.primary,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Don\'t let them fade unseen.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                        height: 1.4,
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
                  onDownload: onConfirmDownload ??
                      ({String? customUrl, bool preferDownloadsFolder = false}) {},
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
                  child: _buildStateIndicator(context, colorScheme, percent),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStateIndicator(BuildContext context, ColorScheme scheme, int? percent) {
    // Ready state
    if (phase == ModelBootPhase.ready) {
      return Center(
        key: const ValueKey('ready'),
        child: Text(
          'Ready!',
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
          ? 'Download canceled'
          : 'Model setup failed';
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
                    Text(phase == ModelBootPhase.paused ? 'Resume' : 'Retry'),
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
            '${_phaseLabel()}… $displayPercent%',
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
  final DownloadCallback onDownload;
  final VoidCallback? onCancel;

  const _DownloadConfirmationCard({
    this.modelSize,
    required this.onDownload,
    this.onCancel,
  });

  @override
  State<_DownloadConfirmationCard> createState() =>
      _DownloadConfirmationCardState();
}

class _DownloadConfirmationCardState extends State<_DownloadConfirmationCard> {
  bool _showAdvanced = false;
  bool _saveToDownloads = false;
  final _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _onToggleSaveToDownloads(bool value) async {
    if (!value) {
      setState(() => _saveToDownloads = false);
      return;
    }

    final status = await Permission.storage.request();
    final granted = status.isGranted ||
        await Permission.manageExternalStorage.isGranted;

    if (!mounted) return;
    if (granted) {
      setState(() => _saveToDownloads = true);
    } else {
      setState(() => _saveToDownloads = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Storage permission denied — saving to app storage instead'),
        ),
      );
    }
  }

  Future<void> _handleDownload() async {
    // Request notification permission (optional - can skip)
    if (mounted) {
      await ModelDownloadNotificationService.requestPermission(context);
    }

    final customUrl = _urlController.text.trim();
    widget.onDownload(
      customUrl: customUrl.isNotEmpty ? customUrl : null,
      preferDownloadsFolder: _saveToDownloads,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

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
                'Download Required',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Column(
                children: [
                  Text(
                    'To identify species, the model',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    'needs to be downloaded${widget.modelSize != null ? ' (${widget.modelSize})' : ''}.',
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
                        'Connect to WiFi before downloading to save mobile data.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (Platform.isAndroid) ...[
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    'Save to Downloads folder',
                    style: theme.textTheme.labelMedium,
                  ),
                  subtitle: Text(
                    'Model survives app reinstall · Requires storage permission',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: _saveToDownloads,
                  onChanged: _onToggleSaveToDownloads,
                ),
              ],
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_showAdvanced ? 'Hide Advanced' : 'Advanced'),
                    Icon(
                      _showAdvanced
                        ? Icons.expand_less
                        : Icons.expand_more,
                    ),
                  ],
                ),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'Custom Model URL',
                    hintText: 'https://...',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 16),
              ],
              FilledButton.icon(
                onPressed: _handleDownload,
                icon: const Icon(Icons.download),
                label: const Text('Download Model'),
              ),
              if (widget.onCancel != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: widget.onCancel,
                  child: const Text('Cancel'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
