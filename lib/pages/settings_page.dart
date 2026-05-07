import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/model_service.dart';
import '../services/permission_service.dart';

class SettingsPage extends StatelessWidget {
  static const Map<String, String> _conservationResources = {
    'IUCN Red List': 'https://www.iucnredlist.org',
    'World Wildlife Fund': 'https://www.worldwildlife.org',
    'Conservation International': 'https://www.conservation.org',
    'CITES': 'https://cites.org',
    'ARKive': 'https://www.arkive.org',
  };

  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final modelService = Provider.of<ModelService>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          // AI Model section
          _sectionHeader('AI Model', colorScheme, textTheme),
          _ModelInfoCard(
            modelService: modelService,
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () => _showModelInfo(context, modelService),
          ),
          const SizedBox(height: 8),
          _iconTile(
            context: context,
            icon: Icons.storage_outlined,
            title: 'Manage Model',
            subtitle: modelService.isModelLoaded ? 'Loaded' : 'Not loaded',
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () => _manageModel(context, modelService),
          ),

          // Permissions section
          _sectionHeader('Permissions', colorScheme, textTheme),
          FutureBuilder<bool>(
            future: PermissionService.hasCameraPermission(),
            builder: (context, snapshot) {
              final granted = snapshot.data ?? false;
              return _permissionTile(
                context: context,
                label: 'Camera',
                isGranted: granted,
                colorScheme: colorScheme,
                textTheme: textTheme,
                onTap: () => _manageCameraPermission(context),
              );
            },
          ),

          // App Information section
          _sectionHeader('Information', colorScheme, textTheme),
          _iconTile(
            context: context,
            icon: Icons.info_outlined,
            title: 'About',
            subtitle: 'Picture That v1.0.0',
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () => _showAboutDialog(context),
          ),
          _iconTile(
            context: context,
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () => _launchUrl('https://example.com/privacy'),
          ),
          _iconTile(
            context: context,
            icon: Icons.description_outlined,
            title: 'Terms of Service',
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () => _launchUrl('https://example.com/terms'),
          ),
          _iconTile(
            context: context,
            icon: Icons.code_outlined,
            title: 'GitHub Repository',
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () =>
                _launchUrl('https://github.com/example/picture-that'),
          ),

          // Conservation Resources section
          _sectionHeader('Conservation Resources', colorScheme, textTheme),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _conservationResources.entries.map((entry) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(entry.key),
                    onPressed: () => _launchUrl(entry.value),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: colorScheme.outline),
                      foregroundColor: colorScheme.tertiary,
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionHeader(
    String title,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: textTheme.labelLarge?.copyWith(color: colorScheme.primary),
      ),
    );
  }

  Widget _iconTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    String? subtitle,
    required ColorScheme colorScheme,
    required TextTheme textTheme,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: colorScheme.onSecondaryContainer, size: 20),
      ),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  Widget _permissionTile({
    required BuildContext context,
    required String label,
    required bool isGranted,
    required ColorScheme colorScheme,
    required TextTheme textTheme,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.camera_alt_outlined,
          color: colorScheme.onSecondaryContainer,
          size: 20,
        ),
      ),
      title: Text(label),
      trailing: Chip(
        label: Text(isGranted ? 'Granted' : 'Denied'),
        backgroundColor: isGranted
            ? colorScheme.tertiaryContainer
            : colorScheme.errorContainer,
        labelStyle: TextStyle(
          color: isGranted
              ? colorScheme.onTertiaryContainer
              : colorScheme.onErrorContainer,
          fontSize: 12,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      onTap: onTap,
    );
  }

  void _showModelInfo(BuildContext context, ModelService modelService) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Model Information'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Gemma 4 E2B (2.4GB)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Status: ${modelService.status}'),
              const SizedBox(height: 8),
              const Text('Capabilities:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Text('• Multimodal (text + image)'),
              const Text('• 1024 token context window'),
              const Text('• On-device inference'),
              const SizedBox(height: 8),
              const Text('Note:',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Text('Model works offline after initial download.'),
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

  void _manageModel(BuildContext context, ModelService modelService) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Manage Model'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current status: ${modelService.status}'),
            const SizedBox(height: 16),
            if (modelService.isModelLoaded) ...[
              const Text('The model is currently loaded and ready for use.'),
              const SizedBox(height: 8),
            ],
            if (!modelService.isModelLoaded && modelService.isInitialized) ...[
              const Text('Model needs to be downloaded before use.'),
              const SizedBox(height: 8),
            ],
          ],
        ),
        actions: [
          if (modelService.isModelLoaded)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                modelService.clearModel();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Model cleared')),
                );
              },
              child: const Text('Clear Model'),
            ),
          if (!modelService.isModelLoaded && modelService.isInitialized)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                modelService.downloadModel();
              },
              child: const Text('Download Model'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _manageCameraPermission(BuildContext context) async {
    final isPermanentlyDenied =
        await PermissionService.isPermissionPermanentlyDenied(Permission.camera);

    if (!context.mounted) return;

    if (isPermanentlyDenied) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Camera Permission Required'),
          content: Text(
            '${PermissionService.getPermissionRationale('camera')}\n\n'
            'This permission has been permanently denied. Please enable it in app settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                PermissionService.openPermissionSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    } else {
      final status = await Permission.camera.request();

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status.isGranted
                ? 'Camera permission granted'
                : 'Camera permission denied',
          ),
        ),
      );
    }
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About Picture That'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Gotta Snap Them All!',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('Version: 1.0.0'),
              const SizedBox(height: 16),
              const Text(
                'This app uses Gemma 4 AI model to identify endangered species from images.',
              ),
              const SizedBox(height: 8),
              const Text(
                'All processing happens on your device for privacy. No images are uploaded to servers.',
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

  Future<void> _launchUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    } catch (e) {
      // Handle error
    }
  }
}

class _ModelInfoCard extends StatelessWidget {
  final ModelService modelService;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final VoidCallback onTap;

  const _ModelInfoCard({
    required this.modelService,
    required this.colorScheme,
    required this.textTheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GestureDetector(
        onTap: onTap,
        child: Card(
          color: colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.model_training_outlined,
                    color: colorScheme.onPrimaryContainer,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Gemma 4 E2B',
                        style: textTheme.titleMedium?.copyWith(
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                      Text(
                        '2.4 GB · On-device inference',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onPrimaryContainer
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(
                    modelService.isModelLoaded ? 'Ready' : 'Not loaded',
                  ),
                  backgroundColor: colorScheme.secondaryContainer,
                  labelStyle: TextStyle(
                    color: colorScheme.onSecondaryContainer,
                    fontSize: 12,
                  ),
                  side: BorderSide.none,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
