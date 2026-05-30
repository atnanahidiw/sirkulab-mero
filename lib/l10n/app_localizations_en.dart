// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Mero';

  @override
  String get appSubtitle => 'Empowering the Guardians of Tomorrow';

  @override
  String get appTagline => 'we can’t protect what we don’t recognize';

  @override
  String get commonSave => 'Save';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonError => 'Error';

  @override
  String get commonLoading => 'Loading...';

  @override
  String get commonReady => 'Ready!';

  @override
  String get commonNone => 'None';

  @override
  String get bootPhasePreparing => 'Preparing';

  @override
  String get bootPhaseChecking => 'Checking';

  @override
  String get bootPhaseNeedsDownload => 'Download Required';

  @override
  String get bootPhaseStarting => 'Starting download';

  @override
  String get bootPhaseDownloading => 'Downloading';

  @override
  String get bootPhaseResuming => 'Resuming';

  @override
  String get bootPhasePaused => 'Paused';

  @override
  String get bootPhaseCanceled => 'Canceled';

  @override
  String get bootPhaseInstalling => 'Installing';

  @override
  String get bootPhaseFailed => 'Needs attention';

  @override
  String get bootPhaseReady => 'Ready';

  @override
  String get bootPhaseAnalyzing => 'Working';

  @override
  String get bootDownloadCanceled => 'Download canceled';

  @override
  String get bootSetupFailed => 'Model setup failed';

  @override
  String get bootResume => 'Resume';

  @override
  String get bootIdentifySpeciesModel => 'To identify species, the model';

  @override
  String bootNeedsToBeDownloaded(String size) {
    return 'needs to be downloaded$size.';
  }

  @override
  String get bootWifiWarning =>
      'Connect to WiFi before downloading to save mobile data.';

  @override
  String get bootAdvanced => 'Advanced';

  @override
  String get bootHideAdvanced => 'Hide Advanced';

  @override
  String get bootCustomModelUrl => 'Custom Model URL';

  @override
  String get bootGrantPermission => 'Grant Permission';

  @override
  String get bootDownloadModel => 'Download Model';

  @override
  String get homeNoCameras => 'No cameras available';

  @override
  String homeCameraInitError(String error) {
    return 'Failed to initialize camera: $error';
  }

  @override
  String get homeCameraPermissionRequired => 'Camera Permission Required';

  @override
  String get homeCameraPermissionDeniedPermanently =>
      'This permission has been permanently denied. Please enable it in app settings.';

  @override
  String get homeOpenSettings => 'Open Settings';

  @override
  String get homeCameraAccess => 'Camera Access';

  @override
  String get homeNotNow => 'Not Now';

  @override
  String get homeAllow => 'Allow';

  @override
  String get homeCameraPermissionRequiredToTakePhotos =>
      'Camera permission is required to take photos';

  @override
  String get homeDownloadModelFirst => 'Please download the model first';

  @override
  String homeFailedToReadImage(String error) {
    return 'Failed to read image: $error';
  }

  @override
  String homeFailedToAnalyzeImage(String error) {
    return 'Failed to analyze image: $error';
  }

  @override
  String get homeCameraUnavailable => 'Camera unavailable';

  @override
  String get homeModelStatusReady => 'Model Ready';

  @override
  String get homeModelStatusError => 'Model Error';

  @override
  String get homeModelStatusLoading => 'Loading…';

  @override
  String get homeModelStatusTapToDownload => 'Tap to Download';

  @override
  String get homeAiModel => 'AI Model';

  @override
  String get homeDownloadModelWithButton => 'Download Model (0.5GB)';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsManageModel => 'Manage Model';

  @override
  String get settingsModelLoaded => 'Loaded';

  @override
  String get settingsModelNotLoaded => 'Not loaded';

  @override
  String get settingsPermissions => 'Permissions';

  @override
  String get settingsCamera => 'Camera';

  @override
  String get settingsPermissionGranted => 'Granted';

  @override
  String get settingsPermissionDenied => 'Denied';

  @override
  String get settingsInformation => 'Information';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsPrivacyPolicy => 'Privacy Policy';

  @override
  String get settingsTermsOfService => 'Terms of Service';

  @override
  String get settingsGithubRepository => 'GitHub Repository';

  @override
  String get settingsConservationResources => 'Conservation Resources';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsModelInfo => 'Model Information';

  @override
  String get settingsModelName => 'FastVLM 0.5B (0.5GB)';

  @override
  String settingsStatus(String status) {
    return 'Status: $status';
  }

  @override
  String get settingsCapabilities => 'Capabilities:';

  @override
  String get settingsCapabilityMultimodal => '• Multimodal (text + image)';

  @override
  String get settingsCapabilityContext => '• 2048 token context window';

  @override
  String get settingsCapabilityInference => '• On-device inference';

  @override
  String get settingsNote => 'Note:';

  @override
  String get settingsOfflineNote =>
      'Model works offline after initial download.';

  @override
  String settingsCurrentStatus(String status) {
    return 'Current status: $status';
  }

  @override
  String get settingsModelLoadedDescription =>
      'The model is currently loaded and ready for use.';

  @override
  String get settingsModelNeedsDownloadDescription =>
      'Model needs to be downloaded before use.';

  @override
  String get settingsClearModel => 'Clear Model';

  @override
  String get settingsClose => 'Close';

  @override
  String get settingsCameraPermissionGranted => 'Camera permission granted';

  @override
  String get settingsCameraPermissionDenied => 'Camera permission denied';

  @override
  String get settingsAboutMero => 'About Mero';

  @override
  String settingsVersion(String version) {
    return 'Version: $version';
  }

  @override
  String get settingsAppDescription =>
      'This app uses the FastVLM AI model to identify endangered species from images.';

  @override
  String get settingsPrivacyDescription =>
      'All processing happens on your device for privacy. No images are uploaded to servers.';

  @override
  String get analyzeTitle => 'Analyzing...';

  @override
  String get analyzeFailed => 'Analysis failed';

  @override
  String get analyzeGoBack => 'Go Back';

  @override
  String get analyzeMsg1 => 'Consulting the wildlife encyclopedia... 📚';

  @override
  String get analyzeMsg2 => 'Asking the AI to put on its glasses... 🤓';

  @override
  String get analyzeMsg3 => 'Cross-referencing with 10,000 species... 🔍';

  @override
  String get analyzeMsg4 => 'The AI is squinting really hard... 👀';

  @override
  String get analyzeMsg5 => 'Enhancing... enhancing... 🔬';

  @override
  String get analyzeMsg6 => 'Running through the jungle database... 🌿';

  @override
  String get analyzeMsg7 => 'Teaching the AI what fur looks like... 🐾';

  @override
  String get analyzeMsg8 => 'Comparing pixels to paws... 🐾';

  @override
  String get analyzeMsg9 => 'Flipping through nature magazines... 📰';

  @override
  String get analyzeMsg10 => 'Sharpening AI neurons... 🧠';

  @override
  String get analyzeMsg11 => 'Downloading more RAM... just kidding! 😄';

  @override
  String get analyzeMsg12 => 'Calibrating the species-o-meter... 📡';

  @override
  String get analyzeMsg13 => 'Making sure it\'s not just a fancy cat... 🐱';

  @override
  String get analyzeMsg14 => 'Double-checking with a botanist friend... 🌺';

  @override
  String get resultSpecies => 'Species';

  @override
  String get resultAnalysisResult => 'Analysis Result';

  @override
  String get resultErrorProcessing =>
      'I apologize, but I encountered an error while processing your question. Please try again.';

  @override
  String get resultCopied => 'Analysis copied to clipboard';

  @override
  String resultFailedToCopy(String error) {
    return 'Failed to copy: $error';
  }

  @override
  String get resultNotRecognized => 'Species not recognized';

  @override
  String get resultTryDifferentAngle =>
      'Try taking the photo from a different angle or with adequate lighting for better results.';

  @override
  String get resultRetakePhoto => 'Retake Photo';

  @override
  String get resultNotEndangered => 'Not Listed as Endangered';

  @override
  String get resultEndangered => 'Endangered';

  @override
  String resultRemaining(String count) {
    return 'Remaining: $count';
  }

  @override
  String get resultSource => 'source';

  @override
  String get resultAskAboutSpecies => 'Ask about this species...';

  @override
  String resultInitialMsgNotListed(String name) {
    return 'Great job spotting the $name! What would you like to know about this species? Feel free to ask anything!';
  }

  @override
  String resultInitialMsgEndangered(String name, String description) {
    return 'Great job spotting the $name! $description\n\nWhat would you like to know about this amazing species? Feel free to ask anything!';
  }

  @override
  String get hintWhyEndangered => 'Why is this species endangered?';

  @override
  String get hintHowManyLeft => 'How many individuals are left in the wild?';

  @override
  String get hintMainThreats => 'What are the main threats to this species?';

  @override
  String get hintConservationEfforts =>
      'What conservation efforts are being made?';

  @override
  String get hintWhatEat => 'What does this species eat?';

  @override
  String get hintWhereFound => 'Where can this species be found in the wild?';

  @override
  String get hintHowReproduce => 'How does this species reproduce?';

  @override
  String get hintNaturalPredators => 'What are its natural predators?';
}
