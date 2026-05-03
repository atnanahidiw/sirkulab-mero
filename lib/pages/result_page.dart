import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import '../services/model_service.dart';
import '../services/species_service.dart';

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
  final ScrollController _chatController = ScrollController();
  final List<Map<String, dynamic>> _chatMessages = [];
  bool _isAnalyzing = false;
  double _analysisProgress = 0.0;
  String _analysisPhase = '';
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
      CurvedAnimation(parent: _typingAnimationController, curve: Curves.easeInOut),
    );
    _loadSpeciesData();
    _addInitialMessage();
  }

  @override
  void dispose() {
    _questionController.dispose();
    _chatController.dispose();
    _typingAnimationController.dispose();
    super.dispose();
  }

  void _addInitialMessage() {
    final firstSentence = _getFirstSentence(widget.analysisResult);
    final welcomeMessage = _createWelcomeMessage(firstSentence);

    setState(() {
      _chatMessages.add({
        'role': 'assistant',
        'content': welcomeMessage,
        'timestamp': DateTime.now(),
      });
    });
  }

  String _getFirstSentence(String text) {
    // Remove markdown formatting and get first sentence
    String cleaned = text.replaceAll('**', '').replaceAll('*', '').trim();

    // Split by periods, exclamation marks, or question marks
    List<String> sentences = cleaned.split(RegExp(r'[.!?]'));
    if (sentences.isNotEmpty) {
      return sentences[0].trim();
    }
    return cleaned;
  }

  String _getInterestingFact(Species? species) {
    if (species != null && species.facts.isNotEmpty) {
      return 'Did you know? ${species.facts.first}';
    }
    return "It's quite an interesting find!";
  }

  String _createWelcomeMessage(String firstSentence) {
    // Extract species name for personalization
    String? speciesName;
    if (_species != null) {
      speciesName = _species!.name;
    } else if (_isNotListed) {
      speciesName = _notListedName;
    }

    // Create a generic friendly welcome message with fun fact for all species
    final funFact = _getInterestingFact(_species);

    return "Great job spotting the ${speciesName ?? 'creature'}! ${funFact} What would you like to know about this amazing species? Feel free to ask anything!";
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
    // Check for NOT_LISTED format: NOT_LISTED|[common name]|[latin name]
    if (result.startsWith('NOT_LISTED|')) {
      return result; // Return the whole thing for special handling
    }
    return result.replaceAll('**', '').replaceAll('*', '').trim();
  }

  // Check if result is NOT_LISTED format
  bool get _isNotListed => widget.analysisResult.startsWith('NOT_LISTED|');

  // Extract details from NOT_LISTED format
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

  void _onProgress(String phase, double progress) {
    if (mounted) {
      setState(() {
        _analysisPhase = phase;
        _analysisProgress = progress;
      });
    }
  }

  Future<void> _askQuestion() async {
    if (_questionController.text.trim().isEmpty || _isAnalyzing) return;

    final question = _questionController.text.trim();
    _questionController.clear();

    // Add user message to chat
    setState(() {
      _chatMessages.add({
        'role': 'user',
        'content': question,
        'timestamp': DateTime.now(),
      });
      _isAnalyzing = true;
    });

    // Scroll to bottom
    await _scrollToBottom();

    try {
      final modelService = Provider.of<ModelService>(context, listen: false);

      // Create query for the model including the original analysis
      final query = '''
Original Analysis: ${widget.analysisResult}

User Question: $question

Please provide a helpful response about this species based on the original analysis and the user's question.
''';

      // Add a placeholder assistant message that will be streamed into
      DateTime now = DateTime.now();
      setState(() {
        _chatMessages.add({
          'role': 'assistant',
          'content': '',
          'timestamp': now,
        });
      });

      final int streamingIndex = _chatMessages.length - 1;
      int lastTokenCount = 0;

      // Get answer from model with real progress tracking + streaming tokens
      await modelService.askQuestion(
        query,
        onProgress: _onProgress,
        onToken: (token) {
          if (!mounted) return;
          setState(() {
            _chatMessages[streamingIndex]['content'] += token;
          });
          // Throttle scrolling to every 5 tokens to avoid performance issues
          lastTokenCount++;
          if (lastTokenCount % 5 == 0) {
            _scrollToBottom();
          }
        },
      );

      // Final scroll to bottom
      _scrollToBottom();

      // Complete progress bar, then hide
      await Future.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;
      setState(() {
        _isAnalyzing = false;
        _analysisProgress = 0.0;
        _analysisPhase = '';
      });
    } catch (e) {
      setState(() {
        _analysisProgress = 0.0;
        _analysisPhase = '';
        _chatMessages.add({
          'role': 'assistant',
          'content':
              'I apologize, but I encountered an error while processing your question. Please try again.',
          'timestamp': DateTime.now(),
        });
        _isAnalyzing = false;
      });
      _scrollToBottom();
    }
  }

  Future<void> _scrollToBottom() async {
    await Future.delayed(const Duration(milliseconds: 100));
    if (_chatController.hasClients) {
      _chatController.animateTo(
        _chatController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// Launch URL in browser
  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    } catch (e) {
      debugPrint('Failed to launch URL: $e');
    }
  }

  /// Animated typing indicator widget with bouncing dots
  /// Animated bouncing dots, shown inside the streaming message bubble
  Widget _buildTypingDots() {
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
                  decoration: const BoxDecoration(
                    color: Colors.green,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analysis Result'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => _shareResult(context),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () => _copyToClipboard(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // Image at top
          Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Image.memory(widget.imageBytes, height: 200),
            ),
          ),

          // Species info (first sentence only)
          Expanded(
            child: Column(
              children: [
                // Quick info section
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(16)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_species == null && !_isNotListed) ...[
                        const Center(
                          child: Text(
                            "Species not recognized",
                            style:
                                TextStyle(fontSize: 16, color: Colors.grey),
                          ),
                        ),
                      ] else if (_isNotListed) ...[
                        Text(
                          _notListedName ?? 'Unknown',
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        if (_notListedLatinName != null &&
                            _notListedLatinName!.isNotEmpty)
                          Text(
                            _notListedLatinName!,
                            style: TextStyle(
                              fontSize: 14,
                              fontStyle: FontStyle.italic,
                              color: Colors.grey[600],
                            ),
                          ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.green[50],
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: Colors.green[300]!),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.check_circle,
                                  size: 16, color: Colors.green[700]),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "Not listed as endangered species",
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.green[700],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        Text(
                          _species!.name,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        if (_species!.latinName.isNotEmpty)
                          Text(
                            _species!.latinName,
                            style: TextStyle(
                              fontSize: 14,
                              fontStyle: FontStyle.italic,
                              color: Colors.grey[600],
                            ),
                          ),
                        if (_species!.populationEstimate != null) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.amber[50],
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: Colors.amber[300]!),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.warning_amber,
                                    size: 16,
                                    color: Colors.amber[800]),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        "Remaining: ${_species!.populationEstimate}",
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.amber[800],
                                        ),
                                      ),
                                      if (_species!.sourceUri != null) ...[
                                        const SizedBox(height: 4),
                                        InkWell(
                                          onTap: () => _launchUrl(
                                              _species!.sourceUri!),
                                          child: Row(
                                            mainAxisSize:
                                                MainAxisSize.min,
                                            children: [
                                              Icon(Icons.link,
                                                  size: 12,
                                                  color:
                                                      Colors.amber[600]),
                                              const SizedBox(width: 4),
                                              Text(
                                                'source',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color:
                                                      Colors.amber[600],
                                                  decoration:
                                                      TextDecoration
                                                          .underline,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),

                // Chat interface
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(16)),
                    ),
                    child: Column(
                      children: [
                        // Chat header
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.blue[100],
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(16)),
                          ),
                          child: const Text(
                            'Ask about this species',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1565C0),
                            ),
                          ),
                        ),

                        // Messages list
                        Expanded(
                          child: ListView.builder(
                            controller: _chatController,
                            padding: const EdgeInsets.all(16),
                            itemCount: _chatMessages.length,
                            itemBuilder: (context, index) {
                              final message = _chatMessages[index];
                              final isUser = message['role'] == 'user';
                              final content = message['content'] as String;
                              final isStreaming = !isUser &&
                                  _isAnalyzing &&
                                  index == _chatMessages.length - 1 &&
                                  content.isEmpty;

                              return Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 12),
                                child: Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    if (isUser)
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.blue[500],
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.person,
                                          color: Colors.white,
                                          size: 16,
                                        ),
                                      )
                                    else
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.green[500],
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.smart_toy,
                                          color: Colors.white,
                                          size: 16,
                                        ),
                                      ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Container(
                                        padding:
                                            const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: isUser
                                              ? Colors.blue[100]
                                              : Colors.green[100],
                                          borderRadius:
                                              BorderRadius.circular(16),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            if (isStreaming)
                                              _buildTypingDots(),
                                            if (!isStreaming) ...[                                              Text(
                                                message['content'],
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  color: isUser
                                                      ? Colors.blue[900]
                                                      : Colors
                                                          .green[900],
                                                ),
                                              ),
                                            ],
                                            const SizedBox(height: 4),
                                            Text(
                                              _formatTime(
                                                  message['timestamp']),
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: Colors.grey[600],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),

                        // Progress bar for complex questions
                        if (_analysisProgress > 0)
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: _analysisProgress,
                                  minHeight: 4,
                                  backgroundColor: Colors.grey[200],
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                          Color(0xFF2196F3)),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 4),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _analysisPhase.isNotEmpty
                                          ? _analysisPhase
                                          : 'Processing question...',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                    Text(
                                      '${(_analysisProgress * 100).toInt()}%',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),

                        // Input area
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: const BorderRadius.vertical(
                                bottom: Radius.circular(16)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.grey[300]!,
                                blurRadius: 4,
                                offset: const Offset(0, -2),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _questionController,
                                  decoration: InputDecoration(
                                    hintText:
                                        'Ask a question about this species...',
                                    hintStyle:
                                        TextStyle(color: Colors.grey[500]),
                                    border: OutlineInputBorder(
                                      borderRadius:
                                          BorderRadius.circular(24),
                                    ),
                                    contentPadding:
                                        const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    suffixIcon: _isAnalyzing
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child:
                                                CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : null,
                                  ),
                                  onSubmitted: (_) => _askQuestion(),
                                  enabled: !_isAnalyzing,
                                ),
                              ),
                              const SizedBox(width: 12),
                              IconButton(
                                onPressed:
                                    _isAnalyzing ? null : _askQuestion,
                                icon: const Icon(Icons.send),
                                style: IconButton.styleFrom(
                                  backgroundColor: const Color(0xFF2196F3),
                                  foregroundColor: Colors.white,
                                  shape: const CircleBorder(),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime? timestamp) {
    if (timestamp == null) return '';
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inSeconds < 60) {
      return 'just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${difference.inDays}d ago';
    }
  }

  Future<void> _shareResult(BuildContext context) async {
    String text;
    if (_species != null) {
      text =
          'Endangered Species: ${_species!.name}\n\n${_species!.description}';
    } else if (_isNotListed) {
      text =
          'Species: $_notListedName\nLatin: $_notListedLatinName\n\nNot listed as endangered species';
    } else {
      text = 'Analysis Result:\n\n${widget.analysisResult}';
    }

    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Result copied to clipboard')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to share: $e')),
      );
    }
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
