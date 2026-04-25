import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
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
          (s) =>
              s.name.toLowerCase().contains(speciesName.toLowerCase()) ||
              speciesName.toLowerCase().contains(s.name.toLowerCase()),
          orElse: () =>
              Species(name: '', latinName: '', description: '', facts: []),
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
    return result.replaceAll('**', '').replaceAll('*', '').trim();
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

              if (_species == null) ...[
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: Text(
                      "Species not recognized",
                      style: TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                  ),
                ),
              ] else ...[
                Text(
                  _species!.name,
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
                if (_species!.latinName.isNotEmpty)
                  Text(
                    _species!.latinName,
                    style: TextStyle(
                      fontSize: 18,
                      fontStyle: FontStyle.italic,
                      color: Colors.grey[600],
                    ),
                  ),
                if (_species!.populationEstimate != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.amber[50],
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.amber[300]!),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber, size: 16, color: Colors.amber[800]),
                        const SizedBox(width: 8),
                        Text(
                          "Remaining population:",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.amber[700],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '~${_species!.populationEstimate}',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.amber[800],
                                ),
                              ),
                              if (_species!.sourceUri != null) ...[
                                const SizedBox(height: 4),
                                InkWell(
                                  onTap: () => _launchUrl(_species!.sourceUri!),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.link, size: 12, color: Colors.amber[600]),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Source',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.amber[600],
                                          decoration: TextDecoration.underline,
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
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text(
                  _species!.description,
                  style: const TextStyle(fontSize: 18),
                ),
                const SizedBox(height: 30),
                const Text(
                  "Interesting Facts:",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                ..._species!.facts.map((fact) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.star, size: 16, color: Colors.amber),
                          const SizedBox(width: 10),
                          Expanded(
                              child: Text(fact,
                                  style: const TextStyle(fontSize: 16))),
                        ],
                      ),
                    )),
              ],

              const SizedBox(height: 32),

              // Action buttons
              Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                  ),
                  child: const Text("Take More Photos"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareResult(BuildContext context) async {
    final text = _species != null 
      ? 'Endangered Species Analysis: ${_species!.name}\n\n${_species!.description}'
      : 'Endangered Species Analysis:\n\n${widget.analysisResult}';

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
    final text = _species != null 
      ? '${_species!.name}\n${_species!.latinName}\n\n${_species!.description}'
      : widget.analysisResult;

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
