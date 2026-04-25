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
    final modelService = Provider.of<ModelService>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          // Model Settings
          _buildSectionHeader('AI Model'),
          _buildListTile(
            title: 'Model Information',
            subtitle:
                'Gemma 4 E2B (2.4GB)',
            icon: Icons.model_training,
            onTap: () => _showModelInfo(context, modelService),
          ),
          _buildListTile(
            title: 'Manage Model',
            subtitle: modelService.isModelLoaded ? 'Loaded' : 'Not loaded',
            icon: Icons.storage,
            onTap: () => _manageModel(context, modelService),
          ),

          // Permissions
          _buildSectionHeader('Permissions'),
          FutureBuilder<bool>(
            future: PermissionService.hasCameraPermission(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              return _buildPermissionTile(
                'Camera',
                snapshot.data!,
                onTap: () => _manageCameraPermission(context),
              );
            },
          ),

          // App Information
          _buildSectionHeader('Information'),
          _buildListTile(
            title: 'About',
            subtitle: 'Picture That v1.0.0',
            icon: Icons.info,
            onTap: () => _showAboutDialog(context),
          ),
          _buildListTile(
            title: 'Privacy Policy',
            icon: Icons.privacy_tip,
            onTap: () => _launchUrl('https://example.com/privacy'),
          ),
          _buildListTile(
            title: 'Terms of Service',
            icon: Icons.description,
            onTap: () => _launchUrl('https://example.com/terms'),
          ),
          _buildListTile(
            title: 'GitHub Repository',
            icon: Icons.code,
            onTap: () => _launchUrl('https://github.com/example/picture-that'),
          ),

          // Conservation Resources
          _buildSectionHeader('Conservation Resources'),
          ..._conservationResources.entries.map((entry) {
            return _buildListTile(
              title: entry.key,
              icon: Icons.open_in_new,
              onTap: () => _launchUrl(entry.value),
            );
          }),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.grey,
        ),
      ),
    );
  }

  Widget _buildListTile({
    required String title,
    String? subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  Widget _buildPermissionTile(
    String permission,
    bool isGranted, {
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(
        isGranted ? Icons.check_circle : Icons.error_outline,
        color: isGranted ? Colors.green : Colors.orange,
      ),
      title: Text(permission),
      subtitle: Text(isGranted ? 'Granted' : 'Not granted'),
      trailing: const Icon(Icons.chevron_right),
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
              const Text(
                'Gemma 4 E2B (2.4GB)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('Status: ${modelService.status}'),
              const SizedBox(height: 8),
              const Text(
                'Capabilities:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text('• Multimodal (text + image)'),
              const Text('• 1024 token context window'),
              const Text('• On-device inference'),
              const SizedBox(height: 8),
              const Text(
                'Note:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
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
            TextButton(
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
              const Text(
                'Endangered Species Identifier',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text('Version: 1.0.0'),
              const SizedBox(height: 16),
              const Text(
                'This app uses Gemma 4 AI model to identify endangered species from images.',
              ),
              const SizedBox(height: 8),
              const Text(
                'All processing happens on your device for privacy. No images are uploaded to servers.',
              ),
              const SizedBox(height: 16),
              const Text(
                'Made with ❤️ for wildlife conservation.',
                style: TextStyle(fontStyle: FontStyle.italic),
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
