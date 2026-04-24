import 'package:flutter/material.dart';

import '../services/model_boot_state.dart';

class ModelBootSplash extends StatelessWidget {
  final String status;
  final String? error;
  final double? progress;
  final bool isLoading;
  final ModelBootPhase phase;
  final VoidCallback? onRetry;
  final VoidCallback? onCancel;

  const ModelBootSplash({
    super.key,
    required this.status,
    required this.error,
    required this.progress,
    required this.isLoading,
    required this.phase,
    this.onRetry,
    this.onCancel,
  });

  String _phaseLabel() {
    return switch (phase) {
      ModelBootPhase.idle => 'Preparing',
      ModelBootPhase.checking => 'Checking model',
      ModelBootPhase.starting => 'Starting download',
      ModelBootPhase.downloading => 'Downloading',
      ModelBootPhase.resuming => 'Resuming download',
      ModelBootPhase.paused => 'Paused',
      ModelBootPhase.canceled => 'Download canceled',
      ModelBootPhase.installing => 'Installing locally',
      ModelBootPhase.failed => 'Download failed',
      ModelBootPhase.ready => 'Ready',
      ModelBootPhase.analyzing => 'Working',
    };
  }

  bool get _showProgress => isLoading && error == null;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final percent = progress == null
        ? null
        : (progress!.clamp(0.0, 1.0) * 100).round();
    final statusLabel = percent == null || status.contains('%')
        ? status
        : '$status • $percent%';
    final errorTitle = phase == ModelBootPhase.canceled
        ? 'Download canceled'
        : 'Model setup failed';
    final subtitle = switch (phase) {
      ModelBootPhase.starting =>
        'The model is being queued in the background downloader.',
      ModelBootPhase.downloading =>
        'The model is downloading in the background and can survive app suspension.',
      ModelBootPhase.resuming =>
        'The downloader recovered an existing task and is continuing from where it left off.',
      ModelBootPhase.paused =>
        'The transfer paused. You can retry or resume it.',
      ModelBootPhase.canceled =>
        'The download was canceled. You can start it again.',
      ModelBootPhase.installing =>
        'The file finished downloading. FlutterGemma is installing it locally now.',
      ModelBootPhase.failed =>
        'The download did not finish. You can retry from here.',
      ModelBootPhase.checking =>
        'Checking for an existing model before starting a download.',
      ModelBootPhase.ready =>
        'The model is ready and the app will open once the gate clears.',
      ModelBootPhase.analyzing =>
        'Processing an image with the local model.',
      ModelBootPhase.idle =>
        'Preparing the local model environment.',
    };

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              colorScheme.primary.withValues(alpha: 0.95),
              const Color(0xFF08140F),
              const Color(0xFF020403),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 28,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.eco_outlined,
                          color: Colors.white,
                          size: 42,
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Picture That',
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          subtitle,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                color: Colors.white.withValues(alpha: 0.78),
                              ),
                        ),
                        const SizedBox(height: 28),
                        if (error != null) ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: Colors.red.withValues(alpha: 0.35),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.error_outline,
                                      color: Colors.redAccent,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      errorTitle,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  error!,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        color: Colors.white.withValues(alpha: 0.85),
                                      ),
                                ),
                                if (onRetry != null) ...[
                                  const SizedBox(height: 16),
                                  FilledButton.icon(
                                    onPressed: onRetry,
                                    icon: const Icon(Icons.refresh),
                                    label: Text(
                                      phase == ModelBootPhase.paused
                                          ? 'Resume'
                                          : 'Retry',
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ] else ...[
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.downloading_outlined,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _phaseLabel(),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                if (_showProgress && progress == null) ...[
                                  const Center(
                                    child: SizedBox(
                                      width: 36,
                                      height: 36,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ] else ...[
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: LinearProgressIndicator(
                                      minHeight: 10,
                                      value: progress,
                                      backgroundColor:
                                          Colors.white.withValues(alpha: 0.12),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        colorScheme.secondaryContainer,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    statusLabel,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'This step happens once. After setup, the app works offline.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.68),
                                ),
                          ),
                          if (onCancel != null && phase != ModelBootPhase.ready) ...[
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              onPressed: onCancel,
                              icon: const Icon(Icons.cancel_outlined),
                              label: const Text('Cancel download'),
                            ),
                          ],
                          if (phase == ModelBootPhase.paused && onRetry != null) ...[
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: onRetry,
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Resume'),
                            ),
                          ],
                          if (phase == ModelBootPhase.canceled && onRetry != null) ...[
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: onRetry,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Retry'),
                            ),
                          ],
                          if (phase == ModelBootPhase.installing) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Installing the downloaded model may take a moment.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.68),
                                  ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
