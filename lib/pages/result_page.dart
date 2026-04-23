import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class _ResultPageState extends State<ResultPage> {
  Species? _species;
  
  @override
  void initState() {
    super.initState();
    _loadSpeciesData();
  }
  
  Future<void> _loadSpeciesData() async {
    try {
      final speciesName = _extractSpeciesName(widget.analysisResult);
      if (speciesName.isNotEmpty) {
        final service = SpeciesService();
        final allSpecies = await service.loadSpecies();
        final matched = allSpecies.firstWhere(
          (s) => s.name.toLowerCase().contains(speciesName.toLowerCase()) ||
                 speciesName.toLowerCase().contains(s.name.toLowerCase()),
          orElse: () => Species(name: '', latinName: '', description: '', facts: []),
        );
        if (matched.name.isNotEmpty) {
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
    // Try to find a header (## Species Name)
    final lines = result.split('\n');
    for (final line in lines) {
      if (line.startsWith('## ')) {
        final name = line.substring(3).trim();
        // Remove any extra markdown
        return name.replaceAll('**', '').replaceAll('*', '').trim();
      }
    }
    // If no header, maybe the first line
    final firstLine = lines.firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    return firstLine.replaceAll('**', '').replaceAll('*', '').trim();
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
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Image
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Image.memory(widget.imageBytes),
                ),
              ),
              
              const SizedBox(height: 24),
              
              // Species details (if found)
              if (_species != null) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.emoji_nature, color: Colors.green),
                            const SizedBox(width: 8),
                            Text(
                              _species!.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 20,
                              ),
                            ),
                          ],
                        ),
                        if (_species!.latinName.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            _species!.latinName,
                            style: TextStyle(
                              fontStyle: FontStyle.italic,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          _species!.description,
                          style: const TextStyle(fontSize: 16),
                        ),
                        if (_species!.facts.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          const Text(
                            'Interesting Facts:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ..._species!.facts.map((fact) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4.0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.star, size: 16, color: Colors.amber),
                                const SizedBox(width: 10),
                                Expanded(child: Text(fact)),
                              ],
                            ),
                          )),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
              
              // Analysis result
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.analytics, color: Colors.green),
                          SizedBox(width: 8),
                          Text(
                            'Species Analysis',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _parseAndDisplayResult(widget.analysisResult),
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 24),
              
              // Conservation tips
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.eco, color: Colors.green),
                          SizedBox(width: 8),
                          Text(
                            'Conservation Tips',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'If you encounter an endangered species:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      _buildConservationTips(),
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 32),
              
              // Action buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Analyze Another'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _learnMore(context),
                      icon: const Icon(Icons.search),
                      label: const Text('Learn More'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _parseAndDisplayResult(String result) {
    // Simple parsing for markdown-like formatting
    final lines = result.split('\n');
    final widgets = <Widget>[];
    
    for (final line in lines) {
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 8));
        continue;
      }
      
      // Check for headers
      if (line.startsWith('## ')) {
        widgets.add(
          Text(
            line.substring(3),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: Colors.green,
            ),
          ),
        );
        widgets.add(const SizedBox(height: 8));
      } else if (line.startsWith('# ')) {
        widgets.add(
          Text(
            line.substring(2),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 20,
              color: Colors.green,
            ),
          ),
        );
        widgets.add(const SizedBox(height: 8));
      } else if (line.startsWith('- ') || line.startsWith('• ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 16.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• '),
                Expanded(
                  child: Text(
                    line.substring(2),
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
        );
      } else if (line.startsWith('**') && line.endsWith('**')) {
        widgets.add(
          Text(
            line.substring(2, line.length - 2),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        );
      } else {
        widgets.add(
          Text(
            line,
            style: const TextStyle(fontSize: 16),
          ),
        );
      }
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
  
  Widget _buildConservationTips() {
    const tips = [
      'Observe from a distance - do not disturb',
      'Do not feed wild animals',
      'Stay on marked trails',
      'Report sightings to local conservation authorities',
      'Take photos only, leave no trace',
      'Support habitat conservation efforts',
      'Educate others about the species',
    ];
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: tips.map((tip) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.check_circle, size: 16, color: Colors.green),
            const SizedBox(width: 8),
            Expanded(child: Text(tip)),
          ],
        ),
      )).toList(),
    );
  }
  
  Future<void> _shareResult(BuildContext context) async {
    // Simple share implementation
    final text = 'Endangered Species Analysis:\n\n${widget.analysisResult}';
    
    try {
      await Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Result copied to clipboard')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to share: $e')),
      );
    }
  }
  
  Future<void> _copyToClipboard(BuildContext context) async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.analysisResult));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Analysis copied to clipboard')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to copy: $e')),
      );
    }
  }
  
  Future<void> _learnMore(BuildContext context) async {
    // Could open a web browser with search for the species
    // For now, show a dialog with resources
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Conservation Resources'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Learn more about endangered species conservation:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 12),
              Text('• IUCN Red List: iucnredlist.org'),
              Text('• World Wildlife Fund: worldwildlife.org'),
              Text('• Conservation International: conservation.org'),
              Text('• CITES: cites.org'),
              SizedBox(height: 12),
              Text(
                'Local conservation organizations may have more specific information about species in your area.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}