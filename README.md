# Picture That - Endangered Species Identifier

A Flutter application that uses Gemma 4 AI model running locally on device to identify endangered species from images. Works offline after initial model download.

## Features

- **On-device AI**: Uses Gemma 4 E2B model running locally for privacy and offline use
- **Image Analysis**: Takes photos or selects from gallery for species identification
- **Conservation Info**: Provides conservation status and information about endangered species
- **Minimal Internet**: Only requires internet for initial model download (~2.4GB)
- **Cross-platform**: Works on iOS, Android, Web, macOS, Windows, and Linux

## Prerequisites

1. **Flutter SDK**: Version 3.0.0 or higher
2. **Platform-specific setup**:
   - iOS: Minimum iOS 16.0
   - Android: OpenGL support for GPU acceleration
   - Desktop: Platform-specific dependencies (see below)

## Installation

1. Clone or download this project
2. Install dependencies:
   ```bash
   flutter pub get
   ```
3. Platform-specific setup:

### iOS Setup
Add to `ios/Podfile`:
```ruby
platform :ios, '16.0'  # Required for MediaPipe GenAI
```

Add to `ios/Runner/Info.plist`:
```xml
<key>UIFileSharingEnabled</key>
<true/>
<key>NSLocalNetworkUsageDescription</key>
<string>This app requires local network access for model inference services.</string>
```

### Android Setup
Add to `android/app/src/main/AndroidManifest.xml` (above `</application>`):
```xml
<uses-native-library
    android:name="libOpenCL.so"
    android:required="false"/>
<uses-native-library 
    android:name="libOpenCL-car.so" 
    android:required="false"/>
<uses-native-library 
    android:name="libOpenCL-pixel.so" 
    android:required="false"/>
```

### Web Setup
Add to `web/index.html` (in `<head>` section):
```html
<script type="module">
  import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.27';
  window.FilesetResolver = FilesetResolver;
  window.LlmInference = LlmInference;
</script>
```

### Desktop Setup
See [flutter_gemma desktop documentation](https://github.com/DenisovAV/flutter_gemma/blob/main/DESKTOP_SUPPORT.md) for platform-specific setup.

## Usage

1. **First Run**: The app will prompt to download the Gemma 4 model (~2.4GB). This requires internet connection.
2. **After Download**: Works completely offline.
3. **Take/Select Photo**: Use camera or gallery to select an image.
4. **Analyze**: Tap "Identify Endangered Species" to analyze the image.
5. **View Results**: See species identification, conservation status, and information.

## Model Information

- **Model**: Gemma 4 E2B (2.4GB, int4 quantized)
- **Format**: `.litertlm` (LiteRT-LM format)
- **Capabilities**: Multimodal (text + image), 1024 token context
- **Source**: [HuggingFace - litert-community/gemma-4-E2B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)

## Project Structure

```
lib/
├── main.dart              # App entry point
├── services/
│   └── model_service.dart # Gemma model management
└── pages/
    ├── home_page.dart     # Main screen with camera/gallery
    └── result_page.dart   # Analysis results display
```

## Dependencies

- `flutter_gemma`: On-device Gemma model inference
- `camera`: Camera access for taking photos
- `image_picker`: Image selection from gallery
- `permission_handler`: Camera and photo library permissions
- `provider`: State management

## Building for Release

### iOS
```bash
flutter build ios --release
```

### Android
```bash
flutter build apk --release
# or for app bundle:
flutter build appbundle --release
```

### Web
```bash
flutter build web --release
```

### Desktop
```bash
flutter build macos --release
flutter build windows --release
flutter build linux --release
```

## Limitations

- **Model Size**: 2.4GB download required for first use
- **Accuracy**: Depends on model training data; may not recognize all species
- **Performance**: Inference speed depends on device hardware
- **Battery**: AI inference can be battery-intensive

## Privacy

- All image processing happens locally on device
- No images are uploaded to external servers
- Model runs completely offline after download
- No personal data collection

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and test thoroughly
4. Submit a pull request

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- [flutter_gemma](https://pub.dev/packages/flutter_gemma) by DenisovAV
- [Google Gemma](https://ai.google.dev/gemma) team
- Conservation organizations worldwide

## Support

For issues and questions:
1. Check [flutter_gemma documentation](https://github.com/DenisovAV/flutter_gemma)
2. Open an issue on GitHub
3. Check Flutter documentation for platform-specific issues