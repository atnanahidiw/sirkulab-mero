import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_markdown_plus_latex/flutter_markdown_plus_latex.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import '../services/model_service.dart';
import '../services/species_service.dart';
import '../models/chat_prompts.dart';
import '../l10n/app_localizations.dart';

class ResultPage extends StatefulWidget {
  final Uint8List imageBytes;
  final String analysisResult;

  /// Species resolved by AnalyzingPage before navigation.
  /// When provided, ResultPage renders immediately with no loading state.
  final SpeciesDetail? preloadedSpecies;

  const ResultPage({
    super.key,
    required this.imageBytes,
    required this.analysisResult,
    this.preloadedSpecies,
  });

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage>
    with SingleTickerProviderStateMixin {
  SpeciesDetail? _species;
  final TextEditingController _questionController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _chatMessages = [];
  bool _isAnalyzing = false;
  List<String> _remainingHints = [];
  String? _activeHint;
  static const double _expandedHeight = 340.0;

  late AnimationController _typingAnimationController;
  late Animation<double> _typingAnimation;

  Map<String, dynamic>? _parsedJson;
  bool _hintsInitialized = false;
  bool _recognitionFailed = false;
  bool _hintsInteracted = false;
  bool _initialScrollDone = false;
  AppLocalizations? _l10n;

  @override
  void initState() {
    super.initState();

    _typingAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _typingAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _typingAnimationController, curve: Curves.easeInOut),
    );

    _parseResultJson();

    // Apply preloaded species.
    _species = widget.preloadedSpecies;

    // Recognition failed only if NO DB hit AND NO parsed JSON name.
    _recognitionFailed = _species == null &&
        (_jsonScientificName == null || _jsonScientificName!.isEmpty);

    WidgetsBinding.instance
        .addPostFrameCallback((_) => _performInitialScroll());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _l10n = AppLocalizations.of(context)!;
    if (!_hintsInitialized) {
      _initHintsAndMessage();
      _hintsInitialized = true;
    }
  }

  @override
  void dispose() {
    _questionController.dispose();
    _scrollController.dispose();
    _typingAnimationController.dispose();
    super.dispose();
  }

  // ── Parsing ──────────────────────────────────────────────────────────────

  /// Parse the JSON result from the model.
  void _parseResultJson() {
    try {
      String jsonStr = widget.analysisResult;
      final jsonMatch = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```')
          .firstMatch(widget.analysisResult);
      if (jsonMatch != null) {
        jsonStr = jsonMatch.group(1)!.trim();
      }
      _parsedJson = jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Failed to parse analysis JSON: $e');
      _parsedJson = null;
    }
  }

  /// True when the species was found in the endangered species DB.
  /// Only reliable AFTER _loadSpeciesData completes (sets _species).
  bool get _isListed {
    if (_species == null) return false;
    return _species!.conservationStatus.isNotEmpty;
  }

  String? get _jsonCommonName =>
      _parsedJson?['common_name'] as String?;
  
  String? get _jsonScientificName =>
      _parsedJson?['scientific_name'] as String?;

  /// Chat enabled when AI identified something, even if not in DB.
  bool get _chatEnabled => !_recognitionFailed;

  // ── Hints & welcome message ──────────────────────────────────────────────

  void _initHintsAndMessage() {
    // _species is already set so hints and message are correct on first render.
    _remainingHints = List.from(
      _isListed
          ? ChatPrompts.endangeredHints(_l10n!)
          : ChatPrompts.notEndangeredHints(_l10n!),
    );

    final name = _species?.commonName ?? _jsonCommonName ?? '';
    final description = _isListed ? (_species?.description ?? '') : '';

    final rawBody = description.isNotEmpty
        ? _l10n!.resultInitialMsgEndangered(name, description)
        : (name.isNotEmpty ? _l10n!.resultInitialMsgNotListed(name) : '');

    if (rawBody.isNotEmpty) {
      _chatMessages.add({'role': 'assistant', 'content': rawBody});

      // Translate async and swap message[0] when ready — non-blocking.
      _translateWelcomeMessage(rawBody);
    }
  }

  Future<void> _translateWelcomeMessage(String rawBody) async {
    final translated = await _translateIfNeeded(rawBody);
    if (!mounted || translated == rawBody || _chatMessages.isEmpty) return;
    setState(() {
      _chatMessages[0] = {'role': 'assistant', 'content': translated};
    });
  }

  Future<String> _translateIfNeeded(String bodyText) async {
    if (bodyText.isEmpty) return bodyText;
    try {
      final modelService = Provider.of<ModelService>(context, listen: false);
      final targetLang = _l10n?.localeName == 'id' ? 'Bahasa Indonesia' : 'English';
      return await modelService.translate(bodyText, targetLang);
    } catch (e) {
      debugPrint('Translation failed: $e');
      return bodyText;
    }
  }

  // ── Chat ─────────────────────────────────────────────────────────────────

  List<String> get _currentHintBatch => _remainingHints.take(3).toList();

  Future<void> _askQuestion() async {
    final text = _questionController.text.trim();
    if (text.isEmpty || _isAnalyzing) return;

    _questionController.clear();
    final usedHint = _activeHint;
    _activeHint = null;

    setState(() {
      _chatMessages.add({'role': 'user', 'content': text});
      _chatMessages.add({'role': 'assistant', 'content': ''});
      if (usedHint != null) _remainingHints.remove(usedHint);
      _isAnalyzing = true;
    });

    _scrollToBottom();

    final int streamingIndex = _chatMessages.length - 1;

    try {
      final modelService = Provider.of<ModelService>(context, listen: false);

      // Build context for the system instruction
      final systemContext = ChatPrompts.buildQuestionContext(
        analysisResult: widget.analysisResult,
        speciesName: _species?.commonName ?? _jsonCommonName,
        speciesLatinName: _species?.scientificName ?? _jsonScientificName,
        isEndangered: _isListed,
        populationEstimate: _species?.populationEstimate,
        description: _species?.description,
        facts: _species?.funFacts,
      );

      // Create system instruction with context
      final langName = _l10n!.localeName == 'id' ? 'Bahasa Indonesia' : 'English';
      final systemInstruction = ChatPrompts.answerSystemInstruction(
        langName,
        context: systemContext
      );

      debugPrint('System Instruction: $systemInstruction');

      await modelService.askQuestion(
        text,
        systemInstruction: systemInstruction,
        onProgress: (_, __) {},
        onToken: (token) {
          if (!mounted) return;
          try {
            setState(() {
              _chatMessages[streamingIndex]['content'] += token;
            });
            _scrollToBottom();
          } catch (e) {
            debugPrint('onToken error: $e');
            rethrow;
          }
        },
      );

      _scrollToBottom();
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      setState(() => _isAnalyzing = false);
    } catch (e) {
      debugPrint('_askQuestion caught: $e');
      // Update the existing empty assistant bubble with error text
      // instead of adding a duplicate.
      setState(() {
        if (streamingIndex < _chatMessages.length) {
          _chatMessages[streamingIndex]['content'] =
              'I apologize, but I encountered an error while processing your question. Please try again.';
        } else {
          _chatMessages.add({
            'role': 'assistant',
            'content':
                'I apologize, but I encountered an error while processing your question. Please try again.',
          });
        }
        _isAnalyzing = false;
      });
      if (mounted) _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      try {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } catch (e) {
        debugPrint('ScrollToBottom error: $e');
      }
    }
  }

  void _performInitialScroll() {
    if (_scrollController.hasClients && !_initialScrollDone) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 5000),
        curve: Curves.easeOutCubic,
      );
      _initialScrollDone = true;
    }
  }

  void _onHintTap(String hint) {
    if (!_hintsInteracted) {
      setState(() => _hintsInteracted = true);
    }
    setState(() => _activeHint = hint);
    _questionController.text = hint;
    _questionController.selection = TextSelection.fromPosition(
      TextPosition(offset: hint.length),
    );
  }

  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    } catch (e) {
      debugPrint('Failed to launch URL: $e');
    }
  }

  // ── UI helpers ───────────────────────────────────────────────────────────

  Widget _buildTypingDots(ColorScheme colorScheme) {
    return AnimatedBuilder(
      animation: _typingAnimation,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            final delay = index * 0.2;
            final dotValue =
                ((_typingAnimation.value - delay) % 1.0).clamp(0.0, 1.0);
            final scale = 0.5 + 0.5 * dotValue;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }

  String _speciesDisplayName(AppLocalizations l10n) {
    if (_species != null) return _species!.commonName;
    if (_isListed) return _jsonCommonName ?? l10n.resultSpecies;
    return l10n.resultAnalysisResult;
  }

  @override
  Widget build(BuildContext context) {
    _l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      bottomNavigationBar: _chatEnabled ? _ChatInputBar(
        controller: _questionController,
        isAnalyzing: _isAnalyzing,
        hintBatch: _currentHintBatch,
        colorScheme: colorScheme,
        textTheme: textTheme,
        hintsInteracted: _hintsInteracted,
        onSend: _askQuestion,
        onHintTap: _onHintTap,
      ) : null,
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // Collapsing image header
          SliverAppBar(
            expandedHeight: _expandedHeight,
            pinned: true,
            backgroundColor: colorScheme.surfaceContainer,
            foregroundColor: colorScheme.onSurface,
            leading: AnimatedBuilder(
              animation: _scrollController,
              builder: (context, _) {
                final collapsed = _scrollController.hasClients &&
                    _scrollController.offset >
                        (_expandedHeight - kToolbarHeight);
                return IconButton(
                  icon: Icon(
                    Icons.arrow_back,
                    color: collapsed ? colorScheme.onSurface : Colors.white,
                  ),
                  onPressed: () => Navigator.pop(context),
                );
              },
            ),
            title: AnimatedBuilder(
              animation: _scrollController,
              builder: (context, _) {
                final collapsed = _scrollController.hasClients &&
                    _scrollController.offset >
                        (_expandedHeight - kToolbarHeight);
                return Text(
                  _speciesDisplayName(_l10n!),
                  style: textTheme.titleLarge?.copyWith(
                    color: collapsed ? colorScheme.onSurface : Colors.white,
                  ),
                );
              },
            ),
            actions: [
              AnimatedBuilder(
                animation: _scrollController,
                builder: (context, _) {
                  final collapsed = _scrollController.hasClients &&
                      _scrollController.offset >
                          (_expandedHeight - kToolbarHeight);
                  return IconButton(
                    icon: Icon(
                      Icons.copy_outlined,
                      color: collapsed ? colorScheme.onSurface : Colors.white,
                    ),
                    onPressed: () => _copyToClipboard(context, _l10n!),
                  );
                },
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(widget.imageBytes, fit: BoxFit.cover),
                  // Top scrim — protects back button and action icons
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.0, 0.4],
                        colors: [
                          Colors.black.withValues(alpha: 0.45),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                  // Bottom scrim — darkens toward the title/collapse zone
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        stops: const [0.0, 0.5],
                        colors: [
                          Colors.black.withValues(alpha: 0.55),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              collapseMode: CollapseMode.pin,
            ),
          ),

          // Species info card
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _SpeciesInfoCard(
                species: _species,
                isListed: _isListed,
                recognitionFailed: _recognitionFailed,
                notListedName: _jsonCommonName,
                notListedLatinName: _jsonScientificName,
                colorScheme: colorScheme,
                textTheme: textTheme,
                onSourceTap: _launchUrl,
                onRetake: () => Navigator.pop(context),
              ),
            ),
          ),

          // Chat messages — only shown when species is detected
          if (_chatEnabled)
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildChatBubble(
                    _chatMessages[index], index, colorScheme, textTheme),
                childCount: _chatMessages.length,
              ),
            ),

          // Bottom padding
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }

  Widget _buildChatBubble(
    Map<String, dynamic> message,
    int index,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final isUser = message['role'] == 'user';
    final content = message['content'] as String;
    final isStreaming = !isUser &&
        _isAnalyzing &&
        index == _chatMessages.length - 1 &&
        content.isEmpty;

    final bubbleColor = isUser
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHigh;
    final textColor =
        isUser ? colorScheme.onPrimaryContainer : colorScheme.onSurface;

    final borderRadius = isUser
        ? const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(4),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          )
        : const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        margin: EdgeInsets.fromLTRB(
          isUser ? 48 : 16,
          4,
          isUser ? 16 : 48,
          4,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: borderRadius,
        ),
        child: isStreaming
            ? _buildTypingDots(colorScheme)
            : MarkdownBody(
                data: content,
                shrinkWrap: true,
                builders: {'latex': LatexElementBuilder()},
                extensionSet: md.ExtensionSet(
                  [LatexBlockSyntax()],
                  [LatexInlineSyntax()],
                ),
                styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: textTheme.bodyMedium?.copyWith(color: textColor),
                  strong: textTheme.bodyMedium?.copyWith(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                  ),
                  em: textTheme.bodyMedium?.copyWith(
                    color: textColor,
                    fontStyle: FontStyle.italic,
                  ),
                  code: textTheme.bodySmall?.copyWith(
                    color: textColor,
                    backgroundColor: textColor.withValues(alpha: 0.08),
                    fontFamily: 'monospace',
                  ),
                  blockquote: textTheme.bodyMedium?.copyWith(
                    color: textColor.withValues(alpha: 0.75),
                    fontStyle: FontStyle.italic,
                  ),
                  blockquoteDecoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: textColor.withValues(alpha: 0.3),
                        width: 3,
                      ),
                    ),
                  ),
                ),
                onTapLink: (text, href, title) {
                  if (href != null) _launchUrl(href);
                },
              ),
      ),
    );
  }

  Future<void> _copyToClipboard(BuildContext context, AppLocalizations l10n) async {
    String text;
    if (_isListed) {
      text =
          '${_species!.commonName}\n${_species!.scientificName}\n\n${_species!.description}';
    } else if (_species != null) {
      text =
          '$_jsonCommonName\n$_jsonScientificName\n\n${_l10n!.resultNotEndangered}';
    } else {
      text = widget.analysisResult;
    }

    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n!.resultCopied)),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_l10n!.commonError}: $e')),
      );
    }
  }
}

// ─── Species Info Card ───────────────────────────────────────────────────────

class _SpeciesInfoCard extends StatelessWidget {
  final SpeciesDetail? species;
  final bool isListed;
  final bool recognitionFailed;
  final String? notListedName;
  final String? notListedLatinName;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final void Function(String url) onSourceTap;
  final VoidCallback? onRetake;

  const _SpeciesInfoCard({
    required this.species,
    required this.isListed,
    required this.recognitionFailed,
    required this.notListedName,
    required this.notListedLatinName,
    required this.colorScheme,
    required this.textTheme,
    required this.onSourceTap,
    this.onRetake,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Card(
      color: colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (recognitionFailed) ...[
              Icon(
                Icons.image_search_outlined,
                size: 36,
                color: colorScheme.onSecondaryContainer.withValues(alpha: 0.7),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.resultNotRecognized,
                style: textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.resultTryDifferentAngle,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSecondaryContainer.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetake,
                icon: const Icon(Icons.camera_alt_outlined, size: 18),
                label: Text(l10n.resultRetakePhoto),
              ),
            ]
            else if (!isListed) ...[
              Text(
                notListedName ?? 'Unknown',
                style: textTheme.headlineSmall?.copyWith(
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
              if (notListedLatinName != null &&
                  notListedLatinName!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  notListedLatinName!,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Chip(
                label: Text(l10n.resultNotEndangered),
                backgroundColor: colorScheme.tertiaryContainer,
                labelStyle: TextStyle(
                  color: colorScheme.onTertiaryContainer,
                  fontSize: 12,
                ),
                side: BorderSide.none,
                avatar: Icon(Icons.check_circle_outline,
                    size: 16, color: colorScheme.onTertiaryContainer),
              ),
            ] else ...[
              Text(
                species!.commonName,
                style: textTheme.headlineSmall?.copyWith(
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
              if (species!.scientificName.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  species!.scientificName,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              if (species!.populationEstimate.isNotEmpty) ...[
                const SizedBox(height: 10),
                Chip(
                  label: Text(l10n.resultEndangered),
                  backgroundColor: colorScheme.errorContainer,
                  labelStyle: TextStyle(
                    color: colorScheme.onErrorContainer,
                    fontSize: 12,
                  ),
                  side: BorderSide.none,
                  avatar: Icon(Icons.warning_amber_outlined,
                      size: 16, color: colorScheme.onErrorContainer),
                ),
                const SizedBox(height: 6),
                Text(
                  species!.populationEstimate,
                  style: textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSecondaryContainer
                        .withValues(alpha: 0.8),
                  ),
                ),
                if (species!.sourceUri.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () => onSourceTap(species!.sourceUri),
                      child: Text(
                        l10n.resultSource,
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.tertiary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Chat Input Bar ───────────────────────────────────────────────────────────

class _ChatInputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool isAnalyzing;
  final List<String> hintBatch;
  final bool hintsInteracted;

  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final VoidCallback onSend;
  final void Function(String hint) onHintTap;

  const _ChatInputBar({
    required this.controller,
    required this.isAnalyzing,
    required this.hintBatch,
    required this.hintsInteracted,
    required this.colorScheme,
    required this.textTheme,
    required this.onSend,
    required this.onHintTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    // Colors based on whether hints have been interacted with
    final Color outerBg = hintsInteracted
        ? colorScheme.surfaceContainer
        : const Color(0xFF81C784);
    final Color chipBg = hintsInteracted
        ? colorScheme.surfaceContainerHighest
        : const Color(0xFFA5D6A7);
    final Color chipTextColor = hintsInteracted
        ? colorScheme.onSurfaceVariant
        : const Color(0xFF1B5E20);

    final EdgeInsetsGeometry padding = EdgeInsets.only(
      bottom: MediaQuery.of(context).viewInsets.bottom +
          MediaQuery.of(context).padding.bottom +
          8,
      top: 8,
      left: 12,
      right: 12,
    );

    return Container(
      color: outerBg,
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hint chips row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: hintBatch.map((hint) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(hint),
                    onSelected: (_) => onHintTap(hint),
                    selected: false,
                    backgroundColor: chipBg,
                    labelStyle: textTheme.labelMedium?.copyWith(
                      color: chipTextColor,
                    ),
                    side: BorderSide.none,
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
          // Input row
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: !isAnalyzing,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: l10n.resultAskAboutSpecies,
                    hintStyle: TextStyle(
                      color: hintsInteracted
                          ? colorScheme.onSurfaceVariant
                          : const Color(0xFF1B5E20),
                    ),
                    suffixIcon: isAnalyzing
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colorScheme.primary,
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: isAnalyzing ? null : onSend,
                icon: const Icon(Icons.send_rounded),
                style: IconButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  disabledBackgroundColor:
                      colorScheme.primary.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
