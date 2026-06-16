import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_id.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('id')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Mero'**
  String get appTitle;

  /// No description provided for @appSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Empowering the Guardians of Tomorrow'**
  String get appSubtitle;

  /// No description provided for @appTagline.
  ///
  /// In en, this message translates to:
  /// **'we can’t protect what we don’t recognize'**
  String get appTagline;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @commonError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get commonError;

  /// No description provided for @commonLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get commonLoading;

  /// No description provided for @commonReady.
  ///
  /// In en, this message translates to:
  /// **'Ready!'**
  String get commonReady;

  /// No description provided for @commonNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get commonNone;

  /// No description provided for @bootPhasePreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing'**
  String get bootPhasePreparing;

  /// No description provided for @bootPhaseChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking'**
  String get bootPhaseChecking;

  /// No description provided for @bootPhaseNeedsDownload.
  ///
  /// In en, this message translates to:
  /// **'Download Required'**
  String get bootPhaseNeedsDownload;

  /// No description provided for @bootPhaseStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting download'**
  String get bootPhaseStarting;

  /// No description provided for @bootPhaseDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get bootPhaseDownloading;

  /// No description provided for @bootPhaseResuming.
  ///
  /// In en, this message translates to:
  /// **'Resuming'**
  String get bootPhaseResuming;

  /// No description provided for @bootPhasePaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get bootPhasePaused;

  /// No description provided for @bootPhaseCanceled.
  ///
  /// In en, this message translates to:
  /// **'Canceled'**
  String get bootPhaseCanceled;

  /// No description provided for @bootPhaseInstalling.
  ///
  /// In en, this message translates to:
  /// **'Installing'**
  String get bootPhaseInstalling;

  /// No description provided for @bootPhaseFailed.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get bootPhaseFailed;

  /// No description provided for @bootPhaseReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get bootPhaseReady;

  /// No description provided for @bootPhaseAnalyzing.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get bootPhaseAnalyzing;

  /// No description provided for @bootDownloadCanceled.
  ///
  /// In en, this message translates to:
  /// **'Download canceled'**
  String get bootDownloadCanceled;

  /// No description provided for @bootSetupFailed.
  ///
  /// In en, this message translates to:
  /// **'Model setup failed'**
  String get bootSetupFailed;

  /// No description provided for @bootResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get bootResume;

  /// No description provided for @bootIdentifySpeciesModel.
  ///
  /// In en, this message translates to:
  /// **'To identify species, the model'**
  String get bootIdentifySpeciesModel;

  /// No description provided for @bootNeedsToBeDownloaded.
  ///
  /// In en, this message translates to:
  /// **'needs to be downloaded{size}.'**
  String bootNeedsToBeDownloaded(String size);

  /// No description provided for @bootWifiWarning.
  ///
  /// In en, this message translates to:
  /// **'Connect to WiFi before downloading to save mobile data.'**
  String get bootWifiWarning;

  /// No description provided for @bootAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get bootAdvanced;

  /// No description provided for @bootHideAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Hide Advanced'**
  String get bootHideAdvanced;

  /// No description provided for @bootCustomModelUrl.
  ///
  /// In en, this message translates to:
  /// **'Custom Model URL'**
  String get bootCustomModelUrl;

  /// No description provided for @bootGrantPermission.
  ///
  /// In en, this message translates to:
  /// **'Grant Permission'**
  String get bootGrantPermission;

  /// No description provided for @bootDownloadModel.
  ///
  /// In en, this message translates to:
  /// **'Download Model'**
  String get bootDownloadModel;

  /// No description provided for @homeNoCameras.
  ///
  /// In en, this message translates to:
  /// **'No cameras available'**
  String get homeNoCameras;

  /// No description provided for @homeCameraInitError.
  ///
  /// In en, this message translates to:
  /// **'Failed to initialize camera: {error}'**
  String homeCameraInitError(String error);

  /// No description provided for @homeCameraPermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'Camera Permission Required'**
  String get homeCameraPermissionRequired;

  /// No description provided for @homeCameraPermissionDeniedPermanently.
  ///
  /// In en, this message translates to:
  /// **'This permission has been permanently denied. Please enable it in app settings.'**
  String get homeCameraPermissionDeniedPermanently;

  /// No description provided for @homeOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get homeOpenSettings;

  /// No description provided for @homeCameraAccess.
  ///
  /// In en, this message translates to:
  /// **'Camera Access'**
  String get homeCameraAccess;

  /// No description provided for @homeNotNow.
  ///
  /// In en, this message translates to:
  /// **'Not Now'**
  String get homeNotNow;

  /// No description provided for @homeAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get homeAllow;

  /// No description provided for @homeCameraPermissionRequiredToTakePhotos.
  ///
  /// In en, this message translates to:
  /// **'Camera permission is required to take photos'**
  String get homeCameraPermissionRequiredToTakePhotos;

  /// No description provided for @homeDownloadModelFirst.
  ///
  /// In en, this message translates to:
  /// **'Please download the model first'**
  String get homeDownloadModelFirst;

  /// No description provided for @homeFailedToReadImage.
  ///
  /// In en, this message translates to:
  /// **'Failed to read image: {error}'**
  String homeFailedToReadImage(String error);

  /// No description provided for @homeFailedToAnalyzeImage.
  ///
  /// In en, this message translates to:
  /// **'Failed to analyze image: {error}'**
  String homeFailedToAnalyzeImage(String error);

  /// No description provided for @homeCameraUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Camera unavailable'**
  String get homeCameraUnavailable;

  /// No description provided for @homeModelStatusReady.
  ///
  /// In en, this message translates to:
  /// **'Model Ready'**
  String get homeModelStatusReady;

  /// No description provided for @homeModelStatusError.
  ///
  /// In en, this message translates to:
  /// **'Model Error'**
  String get homeModelStatusError;

  /// No description provided for @homeModelStatusLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get homeModelStatusLoading;

  /// No description provided for @homeModelStatusTapToDownload.
  ///
  /// In en, this message translates to:
  /// **'Tap to Download'**
  String get homeModelStatusTapToDownload;

  /// No description provided for @homeAiModel.
  ///
  /// In en, this message translates to:
  /// **'AI Model'**
  String get homeAiModel;

  /// No description provided for @homeDownloadModelWithButton.
  ///
  /// In en, this message translates to:
  /// **'Download Model (2.4GB)'**
  String get homeDownloadModelWithButton;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsManageModel.
  ///
  /// In en, this message translates to:
  /// **'Manage Model'**
  String get settingsManageModel;

  /// No description provided for @settingsModelLoaded.
  ///
  /// In en, this message translates to:
  /// **'Loaded'**
  String get settingsModelLoaded;

  /// No description provided for @settingsModelNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Not loaded'**
  String get settingsModelNotLoaded;

  /// No description provided for @settingsPermissions.
  ///
  /// In en, this message translates to:
  /// **'Permissions'**
  String get settingsPermissions;

  /// No description provided for @settingsCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get settingsCamera;

  /// No description provided for @settingsPermissionGranted.
  ///
  /// In en, this message translates to:
  /// **'Granted'**
  String get settingsPermissionGranted;

  /// No description provided for @settingsPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied'**
  String get settingsPermissionDenied;

  /// No description provided for @settingsInformation.
  ///
  /// In en, this message translates to:
  /// **'Information'**
  String get settingsInformation;

  /// No description provided for @settingsAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// No description provided for @settingsPrivacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get settingsPrivacyPolicy;

  /// No description provided for @settingsTermsOfService.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get settingsTermsOfService;

  /// No description provided for @settingsGithubRepository.
  ///
  /// In en, this message translates to:
  /// **'GitHub Repository'**
  String get settingsGithubRepository;

  /// No description provided for @settingsConservationResources.
  ///
  /// In en, this message translates to:
  /// **'Conservation Resources'**
  String get settingsConservationResources;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsModelInfo.
  ///
  /// In en, this message translates to:
  /// **'Model Information'**
  String get settingsModelInfo;

  /// No description provided for @settingsStatus.
  ///
  /// In en, this message translates to:
  /// **'Status: {status}'**
  String settingsStatus(String status);

  /// No description provided for @settingsCapabilities.
  ///
  /// In en, this message translates to:
  /// **'Capabilities:'**
  String get settingsCapabilities;

  /// No description provided for @settingsCapabilityMultimodal.
  ///
  /// In en, this message translates to:
  /// **'• Multimodal (text + image)'**
  String get settingsCapabilityMultimodal;

  /// No description provided for @settingsCapabilityContext.
  ///
  /// In en, this message translates to:
  /// **'• 2048 token context window'**
  String get settingsCapabilityContext;

  /// No description provided for @settingsCapabilityInference.
  ///
  /// In en, this message translates to:
  /// **'• On-device inference'**
  String get settingsCapabilityInference;

  /// No description provided for @settingsNote.
  ///
  /// In en, this message translates to:
  /// **'Note:'**
  String get settingsNote;

  /// No description provided for @settingsOfflineNote.
  ///
  /// In en, this message translates to:
  /// **'Model works offline after initial download.'**
  String get settingsOfflineNote;

  /// No description provided for @settingsCurrentStatus.
  ///
  /// In en, this message translates to:
  /// **'Current status: {status}'**
  String settingsCurrentStatus(String status);

  /// No description provided for @settingsModelLoadedDescription.
  ///
  /// In en, this message translates to:
  /// **'The model is currently loaded and ready for use.'**
  String get settingsModelLoadedDescription;

  /// No description provided for @settingsModelNeedsDownloadDescription.
  ///
  /// In en, this message translates to:
  /// **'Model needs to be downloaded before use.'**
  String get settingsModelNeedsDownloadDescription;

  /// No description provided for @settingsClearModel.
  ///
  /// In en, this message translates to:
  /// **'Clear Model'**
  String get settingsClearModel;

  /// No description provided for @settingsClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get settingsClose;

  /// No description provided for @settingsCameraPermissionGranted.
  ///
  /// In en, this message translates to:
  /// **'Camera permission granted'**
  String get settingsCameraPermissionGranted;

  /// No description provided for @settingsCameraPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Camera permission denied'**
  String get settingsCameraPermissionDenied;

  /// No description provided for @settingsAboutMero.
  ///
  /// In en, this message translates to:
  /// **'About Mero'**
  String get settingsAboutMero;

  /// No description provided for @settingsVersion.
  ///
  /// In en, this message translates to:
  /// **'Version: {version}'**
  String settingsVersion(String version);

  /// No description provided for @settingsAppDescription.
  ///
  /// In en, this message translates to:
  /// **'This app uses an on-device AI model to identify endangered species from images.'**
  String get settingsAppDescription;

  /// No description provided for @settingsPrivacyDescription.
  ///
  /// In en, this message translates to:
  /// **'All processing happens on your device for privacy. No images are uploaded to servers.'**
  String get settingsPrivacyDescription;

  /// No description provided for @analyzeTitle.
  ///
  /// In en, this message translates to:
  /// **'Analyzing...'**
  String get analyzeTitle;

  /// No description provided for @analyzeFailed.
  ///
  /// In en, this message translates to:
  /// **'Analysis failed'**
  String get analyzeFailed;

  /// No description provided for @analyzeGoBack.
  ///
  /// In en, this message translates to:
  /// **'Go Back'**
  String get analyzeGoBack;

  /// No description provided for @analyzeNarrativeTitle.
  ///
  /// In en, this message translates to:
  /// **'How Mero thinks'**
  String get analyzeNarrativeTitle;

  /// No description provided for @analyzeNarrativeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'The AI reads the photo, checks the species library, and explains the match in simple steps.'**
  String get analyzeNarrativeSubtitle;

  /// No description provided for @analyzeReadPhotoTitle.
  ///
  /// In en, this message translates to:
  /// **'Looking at the photo'**
  String get analyzeReadPhotoTitle;

  /// No description provided for @analyzeReadPhotoBody.
  ///
  /// In en, this message translates to:
  /// **'Looking at shape, color, size, and markings.'**
  String get analyzeReadPhotoBody;

  /// No description provided for @analyzeSearchLibraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Checking clues'**
  String get analyzeSearchLibraryTitle;

  /// No description provided for @analyzeSearchLibraryBody.
  ///
  /// In en, this message translates to:
  /// **'Comparing the clues with the local species database.'**
  String get analyzeSearchLibraryBody;

  /// No description provided for @analyzeChooseMatchTitle.
  ///
  /// In en, this message translates to:
  /// **'Choosing the best match'**
  String get analyzeChooseMatchTitle;

  /// No description provided for @analyzeChooseMatchBody.
  ///
  /// In en, this message translates to:
  /// **'Checking the strongest candidate and confidence.'**
  String get analyzeChooseMatchBody;

  /// No description provided for @analyzeBestMatchTitle.
  ///
  /// In en, this message translates to:
  /// **'Best match'**
  String get analyzeBestMatchTitle;

  /// No description provided for @analyzeShowDetails.
  ///
  /// In en, this message translates to:
  /// **'Show detailed trace'**
  String get analyzeShowDetails;

  /// No description provided for @analyzeHideDetails.
  ///
  /// In en, this message translates to:
  /// **'Hide detailed trace'**
  String get analyzeHideDetails;

  /// No description provided for @analyzeWaitingTrace.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the model trace...'**
  String get analyzeWaitingTrace;

  /// No description provided for @analyzePreparingNextPage.
  ///
  /// In en, this message translates to:
  /// **'Preparing next page...'**
  String get analyzePreparingNextPage;

  /// No description provided for @analyzeStrongMatch.
  ///
  /// In en, this message translates to:
  /// **'Strong match'**
  String get analyzeStrongMatch;

  /// No description provided for @analyzePossibleMatch.
  ///
  /// In en, this message translates to:
  /// **'Possible match'**
  String get analyzePossibleMatch;

  /// No description provided for @analyzeLowConfidence.
  ///
  /// In en, this message translates to:
  /// **'Low confidence'**
  String get analyzeLowConfidence;

  /// No description provided for @analyzeCheckingEvidence.
  ///
  /// In en, this message translates to:
  /// **'Checking the evidence'**
  String get analyzeCheckingEvidence;

  /// No description provided for @analyzeDoneLikelyMatch.
  ///
  /// In en, this message translates to:
  /// **'Done. I have a likely match.'**
  String get analyzeDoneLikelyMatch;

  /// No description provided for @analyzeProtectedSpecies.
  ///
  /// In en, this message translates to:
  /// **'Protected species'**
  String get analyzeProtectedSpecies;

  /// No description provided for @resultSpecies.
  ///
  /// In en, this message translates to:
  /// **'Species'**
  String get resultSpecies;

  /// No description provided for @resultAnalysisResult.
  ///
  /// In en, this message translates to:
  /// **'Analysis Result'**
  String get resultAnalysisResult;

  /// No description provided for @resultErrorProcessing.
  ///
  /// In en, this message translates to:
  /// **'I apologize, but I encountered an error while processing your question. Please try again.'**
  String get resultErrorProcessing;

  /// No description provided for @resultCopied.
  ///
  /// In en, this message translates to:
  /// **'Analysis copied to clipboard'**
  String get resultCopied;

  /// No description provided for @resultFailedToCopy.
  ///
  /// In en, this message translates to:
  /// **'Failed to copy: {error}'**
  String resultFailedToCopy(String error);

  /// No description provided for @resultNotRecognized.
  ///
  /// In en, this message translates to:
  /// **'Species not recognized'**
  String get resultNotRecognized;

  /// No description provided for @resultTryDifferentAngle.
  ///
  /// In en, this message translates to:
  /// **'Try taking the photo from a different angle or with adequate lighting for better results.'**
  String get resultTryDifferentAngle;

  /// No description provided for @resultRetakePhoto.
  ///
  /// In en, this message translates to:
  /// **'Retake Photo'**
  String get resultRetakePhoto;

  /// No description provided for @resultNotEndangered.
  ///
  /// In en, this message translates to:
  /// **'Not Listed as Endangered'**
  String get resultNotEndangered;

  /// No description provided for @resultEndangered.
  ///
  /// In en, this message translates to:
  /// **'Endangered'**
  String get resultEndangered;

  /// No description provided for @resultRemaining.
  ///
  /// In en, this message translates to:
  /// **'Remaining: {count}'**
  String resultRemaining(String count);

  /// No description provided for @resultSource.
  ///
  /// In en, this message translates to:
  /// **'source'**
  String get resultSource;

  /// No description provided for @resultAskAboutSpecies.
  ///
  /// In en, this message translates to:
  /// **'Ask about this species...'**
  String get resultAskAboutSpecies;

  /// No description provided for @resultInitialMsgNotListed.
  ///
  /// In en, this message translates to:
  /// **'Great job spotting the {name}! What would you like to know about this species? Feel free to ask anything!'**
  String resultInitialMsgNotListed(String name);

  /// No description provided for @resultInitialMsgEndangered.
  ///
  /// In en, this message translates to:
  /// **'Great job spotting the {name}! {description}\n\nWhat would you like to know about this amazing species? Feel free to ask anything!'**
  String resultInitialMsgEndangered(String name, String description);

  /// No description provided for @hintWhyEndangered.
  ///
  /// In en, this message translates to:
  /// **'Why is this species endangered?'**
  String get hintWhyEndangered;

  /// No description provided for @hintHowManyLeft.
  ///
  /// In en, this message translates to:
  /// **'How many individuals are left in the wild?'**
  String get hintHowManyLeft;

  /// No description provided for @hintMainThreats.
  ///
  /// In en, this message translates to:
  /// **'What are the main threats to this species?'**
  String get hintMainThreats;

  /// No description provided for @hintConservationEfforts.
  ///
  /// In en, this message translates to:
  /// **'What conservation efforts are being made?'**
  String get hintConservationEfforts;

  /// No description provided for @hintWhatEat.
  ///
  /// In en, this message translates to:
  /// **'What does this species eat?'**
  String get hintWhatEat;

  /// No description provided for @hintWhereFound.
  ///
  /// In en, this message translates to:
  /// **'Where can this species be found in the wild?'**
  String get hintWhereFound;

  /// No description provided for @hintHowReproduce.
  ///
  /// In en, this message translates to:
  /// **'How does this species reproduce?'**
  String get hintHowReproduce;

  /// No description provided for @hintNaturalPredators.
  ///
  /// In en, this message translates to:
  /// **'What are its natural predators?'**
  String get hintNaturalPredators;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'id'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'id':
      return AppLocalizationsId();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
