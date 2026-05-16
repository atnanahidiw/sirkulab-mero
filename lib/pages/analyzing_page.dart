import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/navigation/app_page_route.dart';
import '../l10n/app_localizations.dart';
import '../services/model_service.dart';
import '../services/species_service.dart';
import '../utils/image_utils.dart';
import 'result_page.dart';

class AnalyzingPage extends StatefulWidget {
  final Uint8List rawImageBytes;

  const AnalyzingPage({super.key, required this.rawImageBytes});

  @override
  State<AnalyzingPage> createState() => _AnalyzingPageState();
}

class _AnalyzingPageState extends State<AnalyzingPage>
    with TickerProviderStateMixin {
  List<String> _getMessages(AppLocalizations l10n) => [
        l10n.analyzeMsg1,
        l10n.analyzeMsg2,
        l10n.analyzeMsg3,
        l10n.analyzeMsg4,
        l10n.analyzeMsg5,
        l10n.analyzeMsg6,
        l10n.analyzeMsg7,
        l10n.analyzeMsg8,
        l10n.analyzeMsg9,
        l10n.analyzeMsg10,
        l10n.analyzeMsg11,
        l10n.analyzeMsg12,
        l10n.analyzeMsg13,
        l10n.analyzeMsg14,
      ];

  late AnimationController _pulseController;
  late AnimationController _glowController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _glowAnimation;

  String _currentMessage = '';
  int _messageIndex = 0;
  Timer? _messageTimer;
  bool _messageTimerInitialized = false;
  late final Uint8List _displayBytes;
  bool _imageLoaded = false;
  bool _modelActivating = true;
  bool _toolCalling = false;
  bool _streamStarted = false;
  bool _streamCompleted = false;
  final StringBuffer _streamBuffer = StringBuffer();

  // Species service — used to pre-resolve the DB lookup before navigating,
  // so ResultPage always receives fully-loaded data with no loading flash.
  final _speciesService = SpeciesService();

  @override
  void initState() {
    super.initState();

    _displayBytes = widget.rawImageBytes;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.97, end: 1.03).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _glowAnimation = Tween<double>(begin: 0.08, end: 0.32).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _startAnalysis();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ✅ Safe to call here — context (and l10n) is fully available.
    //    Guard flag prevents re-initialisation on subsequent dependency changes.
    if (!_messageTimerInitialized) {
      _initMessageTimer();
      _messageTimerInitialized = true;
    }
  }

  void _initMessageTimer() {
    final l10n = AppLocalizations.of(context)!;
    final messages = _getMessages(l10n);

    _messageIndex = Random().nextInt(messages.length);
    _currentMessage = messages[_messageIndex];

    _messageTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (mounted) {
        setState(() {
          _messageIndex = (_messageIndex + 1) % messages.length;
          _currentMessage = messages[_messageIndex];
        });
      }
    });
  }

  Future<void> _startAnalysis() async {
    // Give enough time for the transition to finish and for HomePage to dispose the camera
    // This ensures RAM is fully cleared before we start heavy inference
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    final modelService = Provider.of<ModelService>(context, listen: false);

    final compressedBytes = await ImageUtils.compressImage(
      _displayBytes,
      maxWidth: 768,
      maxHeight: 768,  // https://newsletter.maartengrootendorst.com/p/a-visual-guide-to-gemma-4
      quality: 92,
    );

    // Step 1 — run the model to identify the species
    String result = '';
    try {
      result = await modelService.identifySpecies(
        compressedBytes,
        'jpeg',
        onProgress: (phase, progress) {
          if (!mounted) return;
          setState(() {
            if (phase == 'Activating model...') {
              _modelActivating = true;
            } else if (phase == 'Model activated') {
              _modelActivating = false;
            }

            if (phase.startsWith('Running tool:')) {
              _toolCalling = true;
            }
          });
        },
        onToken: (token) {
          if (!mounted) return;
          setState(() {
            if (!_streamStarted) {
              _streamStarted = true;
            }
            _streamBuffer.write(token);
          });
        },
      );
    } catch (e) {
      debugPrint('[AnalyzingPage] identifySpecies failed: $e');
      result = ModelService.noDetectionFallbackJson;
    }

    // Step 2 — resolve the species in the DB while still on the analyzing
    // screen, so ResultPage can render immediately with no loading flash.
    SpeciesDetail? preloadedSpecies;
    if (result.isNotEmpty) {
      preloadedSpecies = await _resolveSpecies(result);
    }

    if (!mounted) return;

    // Small pause so the animation doesn't snap away too abruptly.
    await Future.delayed(const Duration(milliseconds: 100));

    // Return the results to HomePage instead of navigating here.
    // This allows HomePage to keep the camera off during ResultPage.
    Navigator.pop(context, {
      'imageBytes': compressedBytes,
      'analysisResult': result,
      'preloadedSpecies': preloadedSpecies,
    });
  }

  /// Parse [result] JSON and look up the species in the local DB.
  /// Returns null if parsing fails or the species isn't found.
  Future<SpeciesDetail?> _resolveSpecies(String result) async {
    try {
      // Strip optional ```json fences
      String jsonStr = result;
      final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(result);
      if (fence != null) jsonStr = fence.group(1)!.trim();

      final parsed    = jsonDecode(jsonStr) as Map<String, dynamic>;
      final sciName   = (parsed['scientific_name'] as String? ?? '').trim();
      final comName   = (parsed['common_name'] as String? ?? '').trim();

      if (sciName.isEmpty) return null;

      // Try the DB first; fall back to a stub built from the model's JSON
      final matched = await _speciesService.findSpeciesByLatinName(sciName);
      return matched ?? SpeciesDetail(
        scientificName: sciName,
        commonName: comName,
        visualFeatures: '',
        description: parsed['identification_notes'] as String? ?? '',
        conservationStatus: '',
        habitat: '',
        threats: const [],
        ecosystemRole: '',
        humanConnection: '',
        whatStudentsCanDo: const [],
        funFacts: const [],
        habitatTags: const [],
        taxonomy: {
          'genus': parsed['genus'] as String? ?? '',
        },
      );
    } catch (e) {
      debugPrint('[AnalyzingPage] _resolveSpecies failed: $e');
      return null;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _glowController.dispose();
    _messageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    final headline = _analysisHeadline(l10n);
    final subhead = _analysisSubhead(l10n);

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.16),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: Text(
                headline,
                key: ValueKey<String>(headline),
                textAlign: TextAlign.center,
                style: textTheme.headlineSmall?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),

            const SizedBox(height: 32),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.15),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: Text(
                subhead,
                key: ValueKey<String>(subhead),
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),

            const SizedBox(height: 28),

            // Animated image with glow ring
            Expanded(
              flex: 3,
              child: Center(
                child: RepaintBoundary(
                  child: AnimatedBuilder(
                    animation: Listenable.merge(
                        [_pulseController, _glowController]
                    ),
                    builder: (context, child) {
                      return Transform.scale(
                        scale: _pulseAnimation.value,
                        child: Container(
                          margin:
                              const EdgeInsets.symmetric(horizontal: 32),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: colorScheme.primary
                                    .withValues(alpha: _glowAnimation.value),
                                blurRadius: 24,
                                spreadRadius: 6,
                              ),
                            ],
                          ),
                          child: child,
                        ),
                      );
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: _buildImage(),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 32),

            // Progress bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(colorScheme.primary),
                ),
              ),
            ),

            const SizedBox(height: 32),

            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 500),
                          transitionBuilder: (child, animation) {
                            return FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.3),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            );
                          },
                          child: Text(
                            _currentMessage,
                            key: ValueKey<String>(_currentMessage),
                            textAlign: TextAlign.center,
                            style: textTheme.bodyLarge?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildImage() {
    return Image.memory(
      _displayBytes,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      // frameBuilder fades the image in smoothly instead of blinking
      // blank → image. frame == null means the image is still decoding.
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) {
          // Image is ready — mark loaded so we could conditionally hide
          // a placeholder if we ever add one.
          if (!_imageLoaded) {
            // Schedule outside build so we don't call setState mid-build.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _imageLoaded = true);
            });
          }
          return child;
        }
        // Image is still decoding — show a neutral surface placeholder
        // the exact same size so the layout doesn't jump.
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const AspectRatio(aspectRatio: 1),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        debugPrint('[AnalyzingPage] Image.memory decode error: $error');
        return ColoredBox(
          color: Theme.of(context).colorScheme.errorContainer,
          child: AspectRatio(
            aspectRatio: 1,
            child: Icon(
              Icons.broken_image_outlined,
              color: Theme.of(context).colorScheme.onErrorContainer,
              size: 48,
            ),
          ),
        );
      },
    );
  }

  String _analysisHeadline(AppLocalizations l10n) {
    if (_modelActivating) {
      return l10n.analyzeStatusWakingUpAi;
    }
    if (_toolCalling) {
      return l10n.analyzeStatusSearching;
    }
    if (_streamStarted) {
      return l10n.analyzeStatusGeneratingResponse;
    }
    return l10n.analyzeStatusWakingUpAi;
  }

  String _analysisSubhead(AppLocalizations l10n) {
    if (_modelActivating) {
      return l10n.analyzeStatusWakingUpHint;
    }
    if (_toolCalling) {
      return l10n.analyzeStatusSearchingHint;
    }
    if (_streamStarted) {
      return l10n.analyzeStatusStreamingHint;
    }
    return l10n.analyzeStatusIdleHint;
  }
}
