# Build Instructions for Mero

## Prerequisites

### 1. Flutter Installation
```bash
# Install Flutter SDK
# Follow official guide: https://flutter.dev/docs/get-started/install

# Verify installation
flutter --version
# Should show Flutter 3.0.0 or higher
```

### 2. Platform Setup

#### Android
- Android Studio with Android SDK
- Minimum SDK: API 21 (Android 5.0)
- Enable developer options on device/emulator

#### iOS
- macOS with Xcode 14.0 or higher
- iOS 16.0 or higher on target device
- Apple Developer account (for physical devices)

#### Web
- Chrome browser for testing
- Web server for deployment

#### Desktop
- Platform-specific build tools:
  - **macOS**: Xcode Command Line Tools
  - **Windows**: Visual Studio 2019 or higher with C++ workload
  - **Linux**: clang, cmake, ninja-build, libgtk-3-dev

## Step-by-Step Build

### 1. Clone/Download Project
```bash
cd /path/to/project
```

### 2. Install Dependencies
```bash
flutter pub get
```

### 3. Platform-Specific Configuration

#### iOS Configuration
```bash
cd ios
pod install
cd ..
```

Edit `ios/Podfile`:
```ruby
platform :ios, '16.0'
use_frameworks! :linkage => :static
```

Edit `ios/Runner/Info.plist`:
```xml
<key>UIFileSharingEnabled</key>
<true/>
<key>NSLocalNetworkUsageDescription</key>
<string>This app requires local network access for model inference services.</string>
<key>CADisableMinimumFrameDurationOnPhone</key>
<true/>
```

#### Android Configuration
Edit `android/app/src/main/AndroidManifest.xml`:
```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>
<uses-permission android:name="android.permission.INTERNET"/>

<application
    android:requestLegacyExternalStorage="true"
    ...>
    
    <!-- Add above </application> -->
    <uses-native-library
        android:name="libOpenCL.so"
        android:required="false"/>
    <uses-native-library 
        android:name="libOpenCL-car.so" 
        android:required="false"/>
    <uses-native-library 
        android:name="libOpenCL-pixel.so" 
        android:required="false"/>
</application>
```

Edit `android/app/build.gradle`:
```gradle
android {
    compileSdkVersion 34
    defaultConfig {
        minSdkVersion 21
        targetSdkVersion 34
        ...
    }
    ...
}
```

#### Web Configuration
Edit `web/index.html`:
```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Mero</title>
    <script src="flutter.js" defer></script>
    
    <!-- Add this script for MediaPipe -->
    <script type="module">
        import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.27';
        window.FilesetResolver = FilesetResolver;
        window.LlmInference = LlmInference;
    </script>
</head>
<body>
    <script>
        window.addEventListener('load', function(ev) {
            _flutter.loader.loadEntrypoint({
                serviceWorker: {
                    serviceWorkerVersion: serviceWorkerVersion,
                }
            }).then(function(engineInitializer) {
                return engineInitializer.initializeEngine();
            }).then(function(appRunner) {
                return appRunner.runApp();
            });
        });
    </script>
</body>
</html>
```

### 4. Environment Configuration

Create `.env` file (optional for HuggingFace token):
```bash
# Copy example
cp .env.example .env
# Edit .env and add your HuggingFace token if needed
```

### 5. Run in Development

#### Android
```bash
# Connect Android device or start emulator
flutter run -d android
```

#### iOS
```bash
# Connect iOS device or start simulator
flutter run -d ios
```

#### Web
```bash
flutter run -d chrome
```

#### Desktop
```bash
# macOS
flutter run -d macos

# Windows
flutter run -d windows

# Linux
flutter run -d linux
```

### 6. Build for Release

#### Android APK
```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

#### Android App Bundle
```bash
flutter build appbundle --release
# Output: build/app/outputs/bundle/release/app-release.aab
```

#### iOS
```bash
flutter build ios --release --no-codesign
# Open Xcode to sign and archive
```

#### Web
```bash
flutter build web --release
# Output: build/web/
```

#### Desktop
```bash
# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Linux
flutter build linux --release
```

## Troubleshooting

### Common Issues

#### 1. "Camera permission not granted"
- Check manifest/plist permissions
- On Android 6.0+, request runtime permissions
- On iOS, add usage descriptions in Info.plist

#### 2. "Model download failed"
- Check internet connection
- Verify HuggingFace token if required
- Check storage space (need ~3GB free)
- Retry with better network connection

#### 3. "GPU backend not available"
- Android: Ensure OpenGL libraries included
- iOS: Metal should be available on all devices
- Web: Only GPU backend supported
- Desktop: Platform-specific GPU drivers

#### 4. "Out of memory"
- Use smaller model (Gemma 4 E2B instead of E4B)
- Reduce image resolution before analysis
- Close other apps during inference

#### 5. "Platform not supported"
- Check flutter_gemma documentation for platform support
- Ensure correct model format for platform
- Verify Flutter channel is stable

### Debugging

#### Enable Verbose Logging
```dart
// In main.dart
FlutterGemma.initialize(
    huggingFaceToken: hfToken,
    maxDownloadRetries: 10,
    verboseLogging: true,  // Add this
);
```

#### Check Model Installation
```bash
# Check downloaded models location
# Android: /data/data/com.sirkulab.mero/files/models/
# iOS: Documents directory
# Web: Browser cache
```

#### Performance Profiling
```bash
flutter run --profile
# Check performance overlay (P key)
```

## Deployment

### App Stores

#### Google Play Store
1. Build app bundle: `flutter build appbundle`
2. Create keystore if not exists
3. Upload to Google Play Console
4. Fill store listing, content rating, etc.

#### Apple App Store
1. Build iOS app: `flutter build ios`
2. Open Xcode, archive, and upload
3. Submit for review via App Store Connect

### Web Hosting
1. Build web: `flutter build web`
2. Deploy `build/web/` to any static hosting:
   - Firebase Hosting
   - GitHub Pages
   - Netlify
   - Vercel

### Desktop Distribution
- **macOS**: .app bundle or DMG
- **Windows**: .exe installer or portable
- **Linux**: .deb, .rpm, or AppImage

## Maintenance

### Updating Dependencies
```bash
flutter pub upgrade
flutter pub outdated
```

### Updating Model
1. Check for newer Gemma 4 versions on HuggingFace
2. Update model URL in `model_service.dart`
3. Users will need to redownload new model

### Monitoring
- App crashes via Firebase Crashlytics
- Analytics via Google Analytics/Firebase
- User feedback collection

## Support

For issues:
1. Check [flutter_gemma issues](https://github.com/DenisovAV/flutter_gemma/issues)
2. Check [Flutter documentation](https://flutter.dev/docs)
3. Open issue with:
   - Platform and version
   - Error logs
   - Steps to reproduce
   - Device information