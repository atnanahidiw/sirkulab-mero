// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Indonesian (`id`).
class AppLocalizationsId extends AppLocalizations {
  AppLocalizationsId([String locale = 'id']) : super(locale);

  @override
  String get appTitle => 'Mero';

  @override
  String get appSubtitle => 'Memberdayakan Penjaga Masa Depan';

  @override
  String get appTagline =>
      'kita tidak bisa melindungi apa yang tidak kita kenali';

  @override
  String get commonSave => 'Simpan';

  @override
  String get commonCancel => 'Batal';

  @override
  String get commonRetry => 'Coba Lagi';

  @override
  String get commonError => 'Kesalahan';

  @override
  String get commonLoading => 'Memuat...';

  @override
  String get commonReady => 'Siap!';

  @override
  String get commonNone => 'Tidak ada';

  @override
  String get bootPhasePreparing => 'Menyiapkan';

  @override
  String get bootPhaseChecking => 'Memeriksa';

  @override
  String get bootPhaseNeedsDownload => 'Unduhan Diperlukan';

  @override
  String get bootPhaseStarting => 'Memulai unduhan';

  @override
  String get bootPhaseDownloading => 'Mengunduh';

  @override
  String get bootPhaseResuming => 'Melanjutkan';

  @override
  String get bootPhasePaused => 'Ditangguhkan';

  @override
  String get bootPhaseCanceled => 'Dibatalkan';

  @override
  String get bootPhaseInstalling => 'Menginstall';

  @override
  String get bootPhaseFailed => 'Butuh perhatian';

  @override
  String get bootPhaseReady => 'Siap';

  @override
  String get bootPhaseAnalyzing => 'Bekerja';

  @override
  String get bootDownloadCanceled => 'Unduhan dibatalkan';

  @override
  String get bootSetupFailed => 'Penyetelan model gagal';

  @override
  String get bootResume => 'Lanjutkan';

  @override
  String get bootIdentifySpeciesModel =>
      'Untuk mengidentifikasi spesies, model';

  @override
  String bootNeedsToBeDownloaded(String size) {
    return 'perlu diunduh$size.';
  }

  @override
  String get bootWifiWarning =>
      'Hubungkan ke WiFi sebelum mengunduh untuk menghemat data seluler.';

  @override
  String get bootAdvanced => 'Lanjutan';

  @override
  String get bootHideAdvanced => 'Sembunyikan Lanjutan';

  @override
  String get bootCustomModelUrl => 'URL Model Kustom';

  @override
  String get bootGrantPermission => 'Berikan Izin';

  @override
  String get bootDownloadModel => 'Unduh Model';

  @override
  String get homeNoCameras => 'Kamera tidak tersedia';

  @override
  String homeCameraInitError(String error) {
    return 'Gagal menginisialisasi kamera: $error';
  }

  @override
  String get homeCameraPermissionRequired => 'Izin Kamera Diperlukan';

  @override
  String get homeCameraPermissionDeniedPermanently =>
      'Izin ini telah ditolak secara permanen. Harap aktifkan di pengaturan aplikasi.';

  @override
  String get homeOpenSettings => 'Buka Pengaturan';

  @override
  String get homeCameraAccess => 'Akses Kamera';

  @override
  String get homeNotNow => 'Nanti Saja';

  @override
  String get homeAllow => 'Izinkan';

  @override
  String get homeCameraPermissionRequiredToTakePhotos =>
      'Izin kamera diperlukan untuk mengambil foto';

  @override
  String get homeDownloadModelFirst => 'Harap unduh model terlebih dahulu';

  @override
  String homeFailedToReadImage(String error) {
    return 'Gagal membaca gambar: $error';
  }

  @override
  String homeFailedToAnalyzeImage(String error) {
    return 'Gagal menganalisis gambar: $error';
  }

  @override
  String get homeCameraUnavailable => 'Kamera tidak tersedia';

  @override
  String get homeModelStatusReady => 'Model Siap';

  @override
  String get homeModelStatusError => 'Kesalahan Model';

  @override
  String get homeModelStatusLoading => 'Memuat…';

  @override
  String get homeModelStatusTapToDownload => 'Ketuk untuk Mengunduh';

  @override
  String get homeAiModel => 'Model AI';

  @override
  String get homeDownloadModelWithButton => 'Unduh Model (2.4GB)';

  @override
  String get settingsTitle => 'Pengaturan';

  @override
  String get settingsManageModel => 'Kelola Model';

  @override
  String get settingsModelLoaded => 'Dimuat';

  @override
  String get settingsModelNotLoaded => 'Tidak dimuat';

  @override
  String get settingsPermissions => 'Izin';

  @override
  String get settingsCamera => 'Kamera';

  @override
  String get settingsPermissionGranted => 'Diberikan';

  @override
  String get settingsPermissionDenied => 'Ditolak';

  @override
  String get settingsInformation => 'Informasi';

  @override
  String get settingsAbout => 'Tentang';

  @override
  String get settingsPrivacyPolicy => 'Kebijakan Privasi';

  @override
  String get settingsTermsOfService => 'Ketentuan Layanan';

  @override
  String get settingsGithubRepository => 'Repositori GitHub';

  @override
  String get settingsConservationResources => 'Sumber Daya Konservasi';

  @override
  String get settingsLanguage => 'Bahasa';

  @override
  String get settingsModelInfo => 'Informasi Model';

  @override
  String get settingsModelName => 'Gemma 4 E2B (2.4GB)';

  @override
  String settingsStatus(String status) {
    return 'Status: $status';
  }

  @override
  String get settingsCapabilities => 'Kemampuan:';

  @override
  String get settingsCapabilityMultimodal => '• Multimodal (teks + gambar)';

  @override
  String get settingsCapabilityContext => '• Jendela konteks 1024 token';

  @override
  String get settingsCapabilityInference => '• Inferensi pada perangkat';

  @override
  String get settingsNote => 'Catatan:';

  @override
  String get settingsOfflineNote =>
      'Model bekerja secara offline setelah unduhan awal.';

  @override
  String settingsCurrentStatus(String status) {
    return 'Status saat ini: $status';
  }

  @override
  String get settingsModelLoadedDescription =>
      'Model saat ini dimuat dan siap digunakan.';

  @override
  String get settingsModelNeedsDownloadDescription =>
      'Model perlu diunduh sebelum digunakan.';

  @override
  String get settingsClearModel => 'Hapus Model';

  @override
  String get settingsClose => 'Tutup';

  @override
  String get settingsCameraPermissionGranted => 'Izin kamera diberikan';

  @override
  String get settingsCameraPermissionDenied => 'Izin kamera ditolak';

  @override
  String get settingsAboutMero => 'Tentang Mero';

  @override
  String settingsVersion(String version) {
    return 'Versi: $version';
  }

  @override
  String get settingsAppDescription =>
      'Aplikasi ini menggunakan model AI Gemma 4 untuk mengidentifikasi spesies terancam punah dari gambar.';

  @override
  String get settingsPrivacyDescription =>
      'Semua pemrosesan terjadi di perangkat Anda untuk privasi. Tidak ada gambar yang diunggah ke server.';

  @override
  String get analyzeTitle => 'Menganalisis...';

  @override
  String get analyzeFailed => 'Analisis gagal';

  @override
  String get analyzeGoBack => 'Kembali';

  @override
  String get analyzeNarrativeTitle => 'Cara Mero berpikir';

  @override
  String get analyzeNarrativeSubtitle =>
      'AI membaca foto, memeriksa basis data spesies, dan menjelaskan kecocokan dalam langkah sederhana.';

  @override
  String get analyzeReadPhotoTitle => 'Melihat foto';

  @override
  String get analyzeReadPhotoBody =>
      'Melihat bentuk, warna, ukuran, dan tanda-tandanya.';

  @override
  String get analyzeSearchLibraryTitle => 'Memeriksa petunjuk';

  @override
  String get analyzeSearchLibraryBody =>
      'Membandingkan petunjuk dengan basis data spesies lokal.';

  @override
  String get analyzeChooseMatchTitle => 'Memilih kecocokan terbaik';

  @override
  String get analyzeChooseMatchBody =>
      'Memeriksa kandidat terkuat dan tingkat keyakinan.';

  @override
  String get analyzeBestMatchTitle => 'Kecocokan terbaik';

  @override
  String get analyzeShowDetails => 'Tampilkan jejak lengkap';

  @override
  String get analyzeHideDetails => 'Sembunyikan jejak lengkap';

  @override
  String get analyzeWaitingTrace => 'Menunggu jejak model...';

  @override
  String get analyzePreparingNextPage => 'Mempersiapkan halaman berikutnya...';

  @override
  String get analyzeStrongMatch => 'Kecocokan kuat';

  @override
  String get analyzePossibleMatch => 'Kecocokan mungkin';

  @override
  String get analyzeLowConfidence => 'Keyakinan rendah';

  @override
  String get analyzeCheckingEvidence => 'Memeriksa bukti';

  @override
  String get analyzeDoneLikelyMatch =>
      'Selesai. Saya mendapat kecocokan yang paling mungkin.';

  @override
  String get analyzeProtectedSpecies => 'Spesies dilindungi';

  @override
  String get resultSpecies => 'Spesies';

  @override
  String get resultAnalysisResult => 'Hasil Analisis';

  @override
  String get resultErrorProcessing =>
      'Saya minta maaf, tetapi saya mengalami kesalahan saat memproses pertanyaan Anda. Silakan coba lagi.';

  @override
  String get resultCopied => 'Analisis disalin ke papan klip';

  @override
  String resultFailedToCopy(String error) {
    return 'Gagal menyalin: $error';
  }

  @override
  String get resultNotRecognized => 'Spesies tidak dikenali';

  @override
  String get resultTryDifferentAngle =>
      'Coba ambil foto dari sudut yang berbeda atau dengan pencahayaan yang memadai untuk hasil yang lebih baik.';

  @override
  String get resultRetakePhoto => 'Ambil Ulang Foto';

  @override
  String get resultNotEndangered => 'Tidak Ada di Daftar Terancam Punah';

  @override
  String get resultEndangered => 'Terancam Punah';

  @override
  String resultRemaining(String count) {
    return 'Tersisa: $count';
  }

  @override
  String get resultSource => 'sumber';

  @override
  String get resultAskAboutSpecies => 'Tanya tentang spesies ini...';

  @override
  String resultInitialMsgNotListed(String name) {
    return 'Kerja bagus menemukan $name! Apa yang ingin Anda ketahui tentang spesies ini? Jangan ragu untuk bertanya apa pun!';
  }

  @override
  String resultInitialMsgEndangered(String name, String description) {
    return 'Kerja bagus menemukan $name! $description\n\nApa yang ingin Anda ketahui tentang spesies luar biasa ini? Jangan ragu untuk bertanya apa pun!';
  }

  @override
  String get hintWhyEndangered => 'Mengapa spesies ini terancam punah?';

  @override
  String get hintHowManyLeft =>
      'Berapa banyak individu yang tersisa di alam liar?';

  @override
  String get hintMainThreats => 'Apa ancaman utama bagi spesies ini?';

  @override
  String get hintConservationEfforts =>
      'Upaya konservasi apa yang sedang dilakukan?';

  @override
  String get hintWhatEat => 'Apa yang dimakan spesies ini?';

  @override
  String get hintWhereFound =>
      'Di mana spesies ini dapat ditemukan di alam liar?';

  @override
  String get hintHowReproduce => 'Bagaimana spesies ini berkembang biak?';

  @override
  String get hintNaturalPredators => 'Apa pemangsa alaminya?';
}
