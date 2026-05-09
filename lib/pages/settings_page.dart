import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../services/locale_service.dart';
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final modelService = Provider.of<ModelService>(context);
    final localeService = Provider.of<LocaleService>(context);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsTitle),
      ),
      body: ListView(
        children: [
          // Language section
          _sectionHeader(l10n.settingsLanguage, colorScheme, textTheme),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<String>(
              initialValue: localeService.locale?.languageCode ?? 'auto',
              decoration: InputDecoration(
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              items: [
                DropdownMenuItem(
                  value: 'auto',
                  child: Text('${l10n.commonNone} (Auto)'),
                ),
                const DropdownMenuItem(
                  value: 'en',
                  child: Text('English'),
                ),
                const DropdownMenuItem(
                  value: 'id',
                  child: Text('Bahasa Indonesia'),
                ),
              ],
              onChanged: (value) {
                if (value == 'auto') {
                  localeService.setLocale(null);
                } else if (value != null) {
                  localeService.setLocale(Locale(value));
                }
              },
            ),
          ),

          // AI Model section
          _sectionHeader(l10n.homeAiModel, colorScheme, textTheme),
          _ModelInfoCard(
            modelService: modelService,
            colorScheme: colorScheme,
            textTheme: textTheme,
            l10n: l10n,
            onTap: () => _showModelInfo(context, modelService, l10n),
          ),
          const SizedBox(height: 8),
          _iconTile(
            context: context,
            icon: Icons.storage_outlined,
            title: l10n.settingsManageModel,
            subtitle: modelService.isModelLoaded ? l10n.settingsModelLoaded : l10n.settingsModelNotLoaded,
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () => _manageModel(context, modelService, l10n),
          ),

          // Permissions section
          _sectionHeader(l10n.settingsPermissions, colorScheme, textTheme),
          FutureBuilder<bool>(
            future: PermissionService.hasCameraPermission(),
            builder: (context, snapshot) {
              final granted = snapshot.data ?? false;
              return _permissionTile(
                context: context,
                label: l10n.settingsCamera,
                isGranted: granted,
                colorScheme: colorScheme,
                textTheme: textTheme,
                l10n: l10n,
                onTap: () => _manageCameraPermission(context, l10n),
              );
            },
          ),

          // App Information section
          _sectionHeader(l10n.settingsInformation, colorScheme, textTheme),
          _iconTile(
            context: context,
            icon: Icons.info_outlined,
            title: l10n.settingsAbout,
            subtitle: 'Mero v1.0.0',
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () => _showAboutDialog(context, l10n),
          ),
          _iconTile(
            context: context,
            icon: Icons.privacy_tip_outlined,
            title: l10n.settingsPrivacyPolicy,
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () => _launchUrl('https://example.com/privacy'),
          ),
          _iconTile(
            context: context,
            icon: Icons.description_outlined,
            title: l10n.settingsTermsOfService,
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () => _launchUrl('https://example.com/terms'),
          ),
          _iconTile(
            context: context,
            icon: Icons.code_outlined,
            title: l10n.settingsGithubRepository,
            colorScheme: colorScheme,
            textTheme: textTheme,
            onTap: () => _launchUrl('https://github.com/example/mero'),
          ),

          // Conservation Resources section
          _sectionHeader(l10n.settingsConservationResources, colorScheme, textTheme),
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
    required AppLocalizations l10n,
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
        label: Text(isGranted ? l10n.settingsPermissionGranted : l10n.settingsPermissionDenied),
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

  void _showModelInfo(BuildContext context, ModelService modelService, AppLocalizations l10n) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsModelInfo),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.settingsModelName,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(l10n.settingsStatus(modelService.status)),
              const SizedBox(height: 8),
              Text(l10n.settingsCapabilities,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(l10n.settingsCapabilityMultimodal),
              Text(l10n.settingsCapabilityContext),
              Text(l10n.settingsCapabilityInference),
              const SizedBox(height: 8),
              Text(l10n.settingsNote,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(l10n.settingsOfflineNote),
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

  void _manageModel(BuildContext context, ModelService modelService, AppLocalizations l10n) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsManageModel),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.settingsCurrentStatus(modelService.status)),
            const SizedBox(height: 16),
            if (modelService.isModelLoaded) ...[
              Text(l10n.settingsModelLoadedDescription),
              const SizedBox(height: 8),
            ],
            if (!modelService.isModelLoaded && modelService.isInitialized) ...[
              Text(l10n.settingsModelNeedsDownloadDescription),
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
                  SnackBar(content: Text(l10n.settingsClearModel)), // Reusing Clear Model label for snackbar
                );
              },
              child: Text(l10n.settingsClearModel),
            ),
          if (!modelService.isModelLoaded && modelService.isInitialized)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                modelService.downloadModel();
              },
              child: Text(l10n.bootDownloadModel),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.settingsClose),
          ),
        ],
      ),
    );
  }

  Future<void> _manageCameraPermission(BuildContext context, AppLocalizations l10n) async {
    final isPermanentlyDenied =
        await PermissionService.isPermissionPermanentlyDenied(Permission.camera);

    if (!context.mounted) return;

    if (isPermanentlyDenied) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.homeCameraPermissionRequired),
          content: Text(
            '${PermissionService.getPermissionRationale('camera')}\n\n'
            '${l10n.homeCameraPermissionDeniedPermanently}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                PermissionService.openPermissionSettings();
              },
              child: Text(l10n.homeOpenSettings),
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
                ? l10n.settingsCameraPermissionGranted
                : l10n.settingsCameraPermissionDenied,
          ),
        ),
      );
    }
  }

  void _showAboutDialog(BuildContext context, AppLocalizations l10n) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsAboutMero),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.appSubtitle,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(l10n.settingsVersion('1.0.0')),
              const SizedBox(height: 16),
              Text(l10n.settingsAppDescription),
              const SizedBox(height: 8),
              Text(l10n.settingsPrivacyDescription),
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
  final AppLocalizations l10n;
  final VoidCallback onTap;

  const _ModelInfoCard({
    required this.modelService,
    required this.colorScheme,
    required this.textTheme,
    required this.l10n,
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
                        l10n.settingsModelName,
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
                    modelService.isModelLoaded ? l10n.settingsModelLoaded : l10n.settingsModelNotLoaded,
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
