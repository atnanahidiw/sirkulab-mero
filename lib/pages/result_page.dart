import 'dart:async';
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

class ResultPage extends StatefulWidget {
  final Uint8List imageBytes;
  final String analysisResult;

  const ResultPage({
    super.key,
    required this.imageBytes,
    required this.analysisResult,
  });

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage>
    with SingleTickerProviderStateMixin {
  Species? _species;
  final TextEditingController _questionController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _chatMessages = [];
  bool _isAnalyzing = false;
  int _hintBatchStart = 0;
  static const double _expandedHeight = 340.0;

  late AnimationController _typingAnimationController;
  late Animation<double> _typingAnimation;

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
    _loadSpeciesData();
    _addInitialMessage();
  }

  @override
  void dispose() {
    _questionController.dispose();
    _scrollController.dispose();
    _typingAnimationController.dispose();
    super.dispose();
  }

  void _addInitialMessage() {
    final funFact = _getInterestingFact(null);
    final speciesName = _isNotListed ? (_notListedName ?? 'creature') : 'creature';
    setState(() {
      _chatMessages.add({
        'role': 'assistant',
        'content':
            'Great job spotting the $speciesName! $funFact What would you like to know about this amazing species? Feel free to ask anything!',
      });
    });
  }

  String _getInterestingFact(Species? species) {
    if (species != null && species.facts.isNotEmpty) {
      return 'Did you know? ${species.facts.first}';
    }
    return "It's quite an interesting find!";
  }

  Future<void> _loadSpeciesData() async {
    try {
      final speciesName = _extractSpeciesName(widget.analysisResult);
      if (speciesName.isNotEmpty) {
        final service = SpeciesService();
        final matched = await service.findSpeciesByLatinName(speciesName);
        if (matched?.latinName.isNotEmpty == true) {
          setState(() {
            _species = matched;
          });
        }
      }
    } catch (e) {
      debugPrint('Error loading species data: $e');
    }
  }

  String _extractSpeciesName(String result) {
    if (result.startsWith('NOT_LISTED|')) return result;
    return result.replaceAll('**', '').replaceAll('*', '').trim();
  }

  bool get _isNotListed => widget.analysisResult.startsWith('NOT_LISTED|');

  String? get _notListedName {
    if (!_isNotListed) return null;
    final parts = widget.analysisResult.split('|');
    return parts.length >= 2 ? parts[1] : null;
  }

  String? get _notListedLatinName {
    if (!_isNotListed) return null;
    final parts = widget.analysisResult.split('|');
    return parts.length >= 3 ? parts[2] : null;
  }

  List<String> get _currentHintBatch {
    final hints = ChatPrompts.questionHints;
    final start = _hintBatchStart % hints.length;
    final result = <String>[];
    for (int i = 0; i < 3; i++) {
      result.add(hints[(start + i) % hints.length]);
    }
    return result;
  }

  Future<void> _askQuestion() async {
    final text = _questionController.text.trim();
    if (text.isEmpty || _isAnalyzing) return;

    _questionController.clear();

    setState(() {
      _chatMessages.add({'role': 'user', 'content': text});
      _hintBatchStart += 3;
      _isAnalyzing = true;
    });

    await _scrollToBottom();

    try {
      final modelService = Provider.of<ModelService>(context, listen: false);
      final query = ChatPrompts.buildQuery(
        analysisResult: widget.analysisResult,
        userQuestion: text,
      );

      setState(() {
        _chatMessages.add({'role': 'assistant', 'content': ''});
      });

      final int streamingIndex = _chatMessages.length - 1;
      int tokenCount = 0;

      await modelService.askQuestion(
        query,
        onProgress: (_, __) {},
        onToken: (token) {
          if (!mounted) return;
          setState(() {
            _chatMessages[streamingIndex]['content'] += token;
          });
          tokenCount++;
          if (tokenCount % 5 == 0) _scrollToBottom();
        },
      );

      _scrollToBottom();

      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      setState(() => _isAnalyzing = false);
    } catch (e) {
      setState(() {
        _chatMessages.add({
          'role': 'assistant',
          'content':
              'I apologize, but I encountered an error while processing your question. Please try again.',
        });
        _isAnalyzing = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _scrollToBottom() async {
    await Future.delayed(const Duration(milliseconds: 100));
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    } catch (e) {
      debugPrint('Failed to launch URL: $e');
    }
  }

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

  String _speciesDisplayName() {
    if (_species != null) return _species!.name;
    if (_isNotListed) return _notListedName ?? 'Species';
    return 'Analysis Result';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      bottomNavigationBar: _ChatInputBar(
        controller: _questionController,
        isAnalyzing: _isAnalyzing,
        hintBatch: _currentHintBatch,
        colorScheme: colorScheme,
        textTheme: textTheme,
        onSend: _askQuestion,
        onHintTap: (hint) {
          _questionController.text = hint;
          _questionController.selection = TextSelection.fromPosition(
            TextPosition(offset: hint.length),
          );
        },
      ),
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
                  _speciesDisplayName(),
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
                    onPressed: () => _copyToClipboard(context),
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
                isNotListed: _isNotListed,
                notListedName: _notListedName,
                notListedLatinName: _notListedLatinName,
                colorScheme: colorScheme,
                textTheme: textTheme,
                onSourceTap: _launchUrl,
              ),
            ),
          ),

          // Chat messages
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

  Future<void> _copyToClipboard(BuildContext context) async {
    String text;
    if (_species != null) {
      text =
          '${_species!.name}\n${_species!.latinName}\n\n${_species!.description}';
    } else if (_isNotListed) {
      text =
          '$_notListedName\n$_notListedLatinName\n\nNot listed as endangered species';
    } else {
      text = widget.analysisResult;
    }

    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Analysis copied to clipboard')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to copy: $e')),
      );
    }
  }
}

// ─── Species Info Card ───────────────────────────────────────────────────────

class _SpeciesInfoCard extends StatelessWidget {
  final Species? species;
  final bool isNotListed;
  final String? notListedName;
  final String? notListedLatinName;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final void Function(String url) onSourceTap;

  const _SpeciesInfoCard({
    required this.species,
    required this.isNotListed,
    required this.notListedName,
    required this.notListedLatinName,
    required this.colorScheme,
    required this.textTheme,
    required this.onSourceTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (species == null && !isNotListed)
              Text(
                'Species not recognized',
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSecondaryContainer,
                ),
              )
            else if (isNotListed) ...[
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
                label: const Text('Not Endangered'),
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
                species!.name,
                style: textTheme.headlineSmall?.copyWith(
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
              if (species!.latinName.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  species!.latinName,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              if (species!.populationEstimate != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Chip(
                      label: Text('Endangered'),
                      backgroundColor: colorScheme.errorContainer,
                      labelStyle: TextStyle(
                        color: colorScheme.onErrorContainer,
                        fontSize: 12,
                      ),
                      side: BorderSide.none,
                      avatar: Icon(Icons.warning_amber_outlined,
                          size: 16, color: colorScheme.onErrorContainer),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Remaining: ${species!.populationEstimate}',
                        style: textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSecondaryContainer
                              .withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                    if (species!.sourceUri != null)
                      GestureDetector(
                        onTap: () => onSourceTap(species!.sourceUri!),
                        child: Text(
                          'source',
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.tertiary,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (species!.description.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),
                MarkdownBody(
                  data: species!.description,
                  shrinkWrap: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(
                    Theme.of(context),
                  ).copyWith(
                    p: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                    ),
                    strong: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                    em: textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
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
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final VoidCallback onSend;
  final void Function(String hint) onHintTap;

  const _ChatInputBar({
    required this.controller,
    required this.isAnalyzing,
    required this.hintBatch,
    required this.colorScheme,
    required this.textTheme,
    required this.onSend,
    required this.onHintTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colorScheme.surfaceContainer,
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).padding.bottom +
            8,
        top: 8,
        left: 12,
        right: 12,
      ),
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
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    labelStyle: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
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
                    hintText: 'Ask about this species...',
                    hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
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
