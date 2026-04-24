import 'package:flutter/material.dart';

import '../services/model_boot_state.dart';

// Minimal splash layout inspired by quex-flutter splash

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
      ModelBootPhase.checking => 'Checking',
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
            // Center: Brand mark and title
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
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Identify endangered species',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  // Balance padding for visual centering
                  const SizedBox(height: 88),
                ],
              ),
            ),
            // Bottom: State indicator
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
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(phase == ModelBootPhase.paused ? 'Resume' : 'Retry'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.primary,
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
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            colorScheme.primaryContainer.withValues(alpha: 0.92),
            colorScheme.primary.withValues(alpha: 0.18),
          ],
        ),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.18),
        ),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: 0.12),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Icon(
        Icons.eco_outlined,
        size: 44,
        color: colorScheme.primary,
      ),
    );
  }
}

