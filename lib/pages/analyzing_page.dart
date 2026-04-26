import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/model_service.dart';
import '../utils/image_utils.dart';
import 'result_page.dart';

/// A dedicated loading page that displays a captured image with animated
/// effects and funny rotating messages while the AI model analyzes the photo.
class AnalyzingPage extends StatefulWidget {
  final Uint8List rawImageBytes;

  const AnalyzingPage({super.key, required this.rawImageBytes});

  @override
  State<AnalyzingPage> createState() => _AnalyzingPageState();
}

class _AnalyzingPageState extends State<AnalyzingPage>
    with TickerProviderStateMixin {
  // Fallback messages used while waiting or if model message generation fails.
  static const List<String> _fallbackMessages = [
    'Consulting the wildlife encyclopedia... 📚',
    'Asking the AI to put on its glasses... 🤓',
    'Cross-referencing with 10,000 species... 🔍',
    'The AI is squinting really hard... 👀',
    'Enhancing... enhancing... 🔬',
    'Running through the jungle database... 🌿',
    'Teaching the AI what fur looks like... 🐾',
    'Comparing pixels to paws... 🐾',
    'Flipping through nature magazines... 📰',
    'Sharpening AI neurons... 🧠',
    'Downloading more RAM... just kidding! 😄',
    'Calibrating the species-o-meter... 📡',
    'Making sure it\'s not just a fancy cat... 🐱',
    'Double-checking with a botanist friend... 🌺',
  ];

  late AnimationController _pulseController;
  late AnimationController _dotController;
  late Animation<double> _pulseAnimation;

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

    _dotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat();

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _currentMessage =
        _fallbackMessages[Random().nextInt(_fallbackMessages.length)];

    // Rotate messages every 12 seconds
    _messageTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (mounted) {
        setState(() {
          _messageIndex = (_messageIndex + 1) % _fallbackMessages.length;
          _currentMessage = _fallbackMessages[_messageIndex];
        });
      }
    });

    // Start analysis
    _startAnalysis();
  }

  Future<void> _startAnalysis() async {
    try {
      final modelService = Provider.of<ModelService>(context, listen: false);

      // Compress in background isolate while showing loading UI
      final compressedBytes = await ImageUtils.compressImage(
        widget.rawImageBytes,
        maxWidth: 800,
        maxHeight: 800,
      );

      // Run species identification on compressed image
      final result =
          await modelService.identifySpecies(compressedBytes, 'jpeg');

      if (!mounted) return;

      // Navigate to result page, replacing this page in the stack
      await Future.delayed(const Duration(milliseconds: 100)); // Small delay to ensure stability
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) => ResultPage(
            imageBytes: compressedBytes,
            analysisResult: result,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
          transitionDuration: const Duration(milliseconds: 300), // Faster transition
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
    _dotController.dispose();
    _messageTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),

            // Title
            const Text(
              'Analyzing...',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),

            const SizedBox(height: 32),

            // Animated image preview
            Expanded(
              flex: 3,
              child: Center(
                child: ScaleTransition(
                  scale: _pulseAnimation,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 32),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.tealAccent.withAlpha(80),
                          blurRadius: 30,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.memory(
                        widget.rawImageBytes,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 32),

            // Scanning animation bar
            if (_isAnalyzing)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    backgroundColor: Colors.white10,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.tealAccent),
                  ),
                ),
              ),

            const SizedBox(height: 32),

            // Funny message with fade transition
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: _error != null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline,
                              color: Colors.redAccent, size: 40),
                          const SizedBox(height: 12),
                          Text(
                            'Analysis failed',
                            style: TextStyle(
                              color: Colors.redAccent.shade100,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: () => Navigator.pop(context),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.tealAccent,
                              foregroundColor: Colors.black,
                            ),
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
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 18,
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
