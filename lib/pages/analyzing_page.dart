import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/navigation/app_page_route.dart';
import '../services/model_service.dart';
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
  static const List<String> _messages = [
    'Consulting the wildlife encyclopedia...',
    'Cross-referencing with 50,000 species records...',
    'Running pixels through the jungle database...',
    'Asking the beetles for a second opinion...',
    'Flipping through field guides, page by page...',
    'Comparing fur patterns at the pixel level...',
    'The AI is squinting at your photo very hard...',
    'Checking the IUCN Red List status...',
    'Double-checking with a botanist friend...',
    'Sharpening neurons, calibrating instincts...',
    'Making sure it\'s not just a very fancy cat...',
    'Running through the rainforest database...',
    'Enhancing... enhancing... almost there...',
    'Scanning habitat markers and field signs...',
  ];

  late AnimationController _pulseController;
  late AnimationController _glowController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _glowAnimation;

  String _currentMessage = '';
  int _messageIndex = 0;
  Timer? _messageTimer;
  bool _isAnalyzing = true;
  String? _error;

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

    _currentMessage = _messages[Random().nextInt(_messages.length)];

    _messageTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (mounted) {
        setState(() {
          _messageIndex = (_messageIndex + 1) % _messages.length;
          _currentMessage = _messages[_messageIndex];
        });
      }
    });

    _startAnalysis();
  }

  Future<void> _startAnalysis() async {
    try {
      final modelService = Provider.of<ModelService>(context, listen: false);

      final compressedBytes = await ImageUtils.compressImage(
        widget.rawImageBytes,
        maxWidth: 336,
        maxHeight: 336,
        quality: 85,
      );

      final result =
          await modelService.identifySpecies(compressedBytes, 'jpeg');

      if (!mounted) return;

      await Future.delayed(const Duration(milliseconds: 100));
      Navigator.pushReplacement(
        context,
        AppPageRoute.slideUp(
          (_) => ResultPage(
            imageBytes: compressedBytes,
            analysisResult: result,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          _error = e.toString();
        });
      }
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

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),

            Text(
              'Analyzing...',
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
            if (_isAnalyzing)
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

            // Message / error
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: _error != null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.error_outline,
                              color: colorScheme.error, size: 40),
                          const SizedBox(height: 12),
                          Text(
                            'Analysis failed',
                            style: textTheme.titleMedium?.copyWith(
                              color: colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.tonal(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Go Back'),
                          ),
                        ],
                      )
                    : AnimatedSwitcher(
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
