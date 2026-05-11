import 'package:flutter_gemma/flutter_gemma.dart';

class ToolSpec {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final Future<String> Function(Map<String, dynamic> args) execute;
  final Message? subsequentPrompt;

  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
    this.subsequentPrompt,
  });

  Tool toTool() => Tool(
    name: name,
    description: description,
    parameters: parameters,
  );

  static List<Tool> toTools(List<ToolSpec> specs) =>
      specs.map((s) => s.toTool()).toList();
}