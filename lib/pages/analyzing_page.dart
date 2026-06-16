import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/model_service.dart';
import '../services/species_service.dart';
import '../utils/image_utils.dart';

class AnalyzingPage extends StatefulWidget {
  final Uint8List rawImageBytes;

  const AnalyzingPage({super.key, required this.rawImageBytes});

  @override
  State<AnalyzingPage> createState() => _AnalyzingPageState();
}

class _AnalyzingPageState extends State<AnalyzingPage>
    with AutomaticKeepAliveClientMixin {
  String _modelOutput = '';
  String _pendingOutput = '';
  late final Uint8List _displayBytes;
  final ScrollController _outputController = ScrollController();
  int _currentTraceIndex = 0;
  Timer? _typewriterTimer;
  bool _modelFinished = false;
  bool _resultReady = false;
  bool _handoffScheduled = false;
  bool _preparingHandoff = false;
  Uint8List? _pendingCompressedBytes;
  String _pendingAnalysisResult = '';
  SpeciesDetail? _pendingSpecies;

  // Species service — used to pre-resolve the DB lookup before navigating,
  // so ResultPage always receives fully-loaded data with no loading flash.
  final _speciesService = SpeciesService();

  @override
  void initState() {
    super.initState();

    _displayBytes = widget.rawImageBytes;

    _startAnalysis();
  }

  void _appendTranscript(String chunk) {
    if (!mounted || chunk.isEmpty) return;

    setState(() {
      _pendingOutput += chunk;
    });

    _startTypewriter();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_outputController.hasClients) return;
      _outputController.jumpTo(_outputController.position.maxScrollExtent);
    });
  }

  void _completeTrace() {
    _currentTraceIndex = 2;
  }

  void _startTypewriter() {
    if (_typewriterTimer?.isActive == true) {
      return;
    }

    _typewriterTimer = Timer.periodic(const Duration(milliseconds: 65), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_pendingOutput.isEmpty) {
        timer.cancel();
        _typewriterTimer = null;
        _maybeScheduleHandoff();
        return;
      }

      final nextChar = _pendingOutput.substring(0, 1);
      setState(() {
        _pendingOutput = _pendingOutput.substring(1);
        _modelOutput += nextChar;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_outputController.hasClients) return;
        _outputController.jumpTo(_outputController.position.maxScrollExtent);
      });
    });
  }

  void _markModelFinished() {
    _modelFinished = true;
    _maybeScheduleHandoff();
  }

  void _maybeScheduleHandoff() {
    if (!_modelFinished || !_resultReady || _handoffScheduled || _pendingOutput.isNotEmpty) {
      return;
    }

    _handoffScheduled = true;
    setState(() => _preparingHandoff = true);
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;

      Navigator.pop(context, {
        'imageBytes': _pendingCompressedBytes,
        'analysisResult': _pendingAnalysisResult,
        'preloadedSpecies': _pendingSpecies,
      });
    });
  }

  @override
  bool get wantKeepAlive => true;

  Future<void> _startAnalysis() async {
    // Give enough time for the transition to finish and for HomePage to dispose the camera
    // This ensures RAM is fully cleared before we start heavy inference
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;

    final l10n = AppLocalizations.of(context)!;
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
      setState(() {
        _currentTraceIndex = 0;
      });
      result = await modelService.identifySpecies(
        compressedBytes,
        'jpeg',
        languageName: _languageName(l10n),
        onProgress: _handleModelProgress,
        onTrace: _appendTranscript,
      );
    } catch (e) {
      debugPrint('[AnalyzingPage] identifySpecies failed: $e');
    }

    // Step 2 — resolve the species in the DB while still on the analyzing
    // screen, so ResultPage can render immediately with no loading flash.
    SpeciesDetail? preloadedSpecies;
    if (result.isNotEmpty) {
      preloadedSpecies = await _resolveSpecies(result);
    }

    // ToDo: Parse 'N/A'

    if (!mounted) return;

    setState(() {
      _completeTrace();
    });

    _pendingCompressedBytes = compressedBytes;
    _pendingAnalysisResult = result;
    _pendingSpecies = preloadedSpecies;
    _resultReady = true;
    _markModelFinished();

    debugPrint('[AnalyzingPage] result: $result\npreloadedSpecies: $preloadedSpecies');
  }

  String _languageName(AppLocalizations l10n) =>
      l10n.localeName == 'id' ? 'Bahasa Indonesia' : 'English';

  /// Parse [result] JSON and look up the species in the local DB.
  /// Returns null if parsing fails or the species isn't found.
  Future<SpeciesDetail?> _resolveSpecies(String result) async {
    try {
      final parsed = _parseJson(result);
      if (parsed == null) return null;

      final sciName = (parsed['scientific_name'] as String? ?? '').trim();
      final comName = (parsed['common_name'] as String? ?? '').trim();

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

  Map<String, dynamic>? _parseJson(String result) {
    try {
      String jsonStr = result;
      final fence =
          RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(result);
      if (fence != null) jsonStr = fence.group(1)!.trim();
      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  void _handleModelProgress(String phase, double progress) {
    final lower = phase.toLowerCase();
    if (!mounted) return;

    setState(() {
      if (lower.contains('complete')) {
        _completeTrace();
      } else if (lower.contains('tool') ||
          lower.contains('identifying') ||
          lower.contains('search') ||
          lower.contains('result')) {
        _currentTraceIndex = 1;
      } else {
        _currentTraceIndex = 0;
      }
    });
  }

  @override
  void dispose() {
    _typewriterTimer?.cancel();
    _outputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    final outputMarkdown = _buildOutputMarkdown(l10n);

    return Scaffold(
      backgroundColor: colorScheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Hero(
                tag: 'analysis-image',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.memory(
                    _displayBytes,
                    height: 200,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: child,
                ),
                child: Text(
                  _phaseLabel(l10n),
                  key: ValueKey(_currentTraceIndex),
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 320,
                child: _buildOutputBox(colorScheme, textTheme, l10n, outputMarkdown),
              ),
              const SizedBox(height: 32),
              AnimatedSize(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                child: _preparingHandoff
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 48),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              l10n.analyzePreparingNextPage,
                              style: textTheme.labelSmall?.copyWith(
                                color: colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _buildOutputMarkdown(AppLocalizations l10n) {
    final text = _modelOutput.trim();
    if (text.isEmpty) return '_${l10n.analyzeWaitingTrace}_';
    return text.replaceAll('\r\n', '\n');
  }

  String _phaseLabel(AppLocalizations l10n) => [
      l10n.analyzeReadPhotoTitle,
      l10n.analyzeSearchLibraryTitle,
      l10n.analyzeChooseMatchTitle,
    ][_currentTraceIndex];

  Widget _buildOutputBox(
    ColorScheme colorScheme,
    TextTheme textTheme,
    AppLocalizations l10n,
    String markdown,
  ) {
    final bodyStyle = textTheme.bodyMedium?.copyWith(
      color: colorScheme.onSurface,
      height: 1.6,
    );
    return SingleChildScrollView(
      controller: _outputController,
      physics: const ClampingScrollPhysics(),
      child: MarkdownBody(
        data: markdown,
        shrinkWrap: true,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: bodyStyle,
          strong: bodyStyle?.copyWith(fontWeight: FontWeight.w600),
          em: bodyStyle?.copyWith(fontStyle: FontStyle.italic),
        ),
      ),
    );
  }

}

