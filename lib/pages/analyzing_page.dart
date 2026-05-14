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

  // Species service — used to pre-resolve the DB lookup before navigating,
  // so ResultPage always receives fully-loaded data with no loading flash.
  final _speciesService = SpeciesService();

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.97, end: 1.03).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _glowAnimation = Tween<double>(begin: 0.1, end: 0.3).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _startAnalysis();
  }

  void _setupMessageTimer(AppLocalizations l10n) {
    if (_messageTimer != null) return;

    final messages = _getMessages(l10n);
    _currentMessage = messages[Random().nextInt(messages.length)];

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

    final modelService = Provider.of<ModelService>(context, listen: false);

    // Step 1 — Split image into 2x2 grid for enriched analysis
    final quadrants = await ImageUtils.splitImageInto2x2Grid(
      widget.rawImageBytes,
    );

    // Step 2 — Compress all 5 images (original + 4 quadrants)
    final compressedBytes = await ImageUtils.compressImage(
      widget.rawImageBytes,
      maxWidth: 1080,
      maxHeight: 1080,  // https://newsletter.maartengrootendorst.com/p/a-visual-guide-to-gemma-4
      quality: 92,
    );

    final compressedQuadrants = await Future.wait(
      quadrants.map((q) => ImageUtils.compressImage(
        q,
        maxWidth: 1080,
        maxHeight: 1080,
        quality: 92,
      )),
    );

    // Step 3 — Run model inference with all 5 images
    String result;
    try {
      result = await modelService.identifySpecies(
        compressedBytes,
        'jpeg',
        additionalImages: compressedQuadrants,
      );
    } catch (e) {
      debugPrint('[AnalyzingPage] identifySpecies failed: $e');
      result = '';
    }

    // Step 4 — Resolve species in DB for immediate ResultPage render
    SpeciesDetail? preloadedSpecies;
    if (result.isNotEmpty) {
      preloadedSpecies = await _resolveSpecies(result);
    }

    if (!mounted) return;

    await Future.delayed(const Duration(milliseconds: 100));

    // Return the results to HomePage instead of navigating here.
    // This allows HomePage to keep the camera off during ResultPage.
    Navigator.pop(context, {
      'imageBytes': compressedBytes,
      'additionalImages': compressedQuadrants,
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
      final sciName   = parsed['scientific_name'] as String? ?? '';
      final comName   = parsed['common_name']     as String? ?? '';

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

    _setupMessageTimer(l10n);

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),

            Text(
              l10n.analyzeTitle,
              style: textTheme.headlineSmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),

            const SizedBox(height: 32),

            // Animated image with glow ring
            Expanded(
              flex: 3,
              child: Center(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_pulseAnimation, _glowAnimation]),
                  builder: (context, child) {
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        // Glow ring
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 24),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: colorScheme.primary
                                    .withValues(alpha: _glowAnimation.value),
                                blurRadius: 40,
                                spreadRadius: 8,
                              ),
                            ],
                          ),
                          child: const SizedBox.shrink(),
                        ),
                        // Image card
                        Transform.scale(
                          scale: _pulseAnimation.value,
                          child: Card(
                            margin: const EdgeInsets.symmetric(horizontal: 32),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: Image.memory(
                                widget.rawImageBytes,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
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

            // Rotating fun messages
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
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

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
