# Mero - Project Summary

## Overview
A Flutter application that uses **Gemma 4 E2B** AI model running **locally on device** to identify Indonesia endangered species from images. The app minimizes internet usage by downloading the model once (~2.4GB) and then working completely offline.

## Key Features

### 1. **On-Device AI Inference**
- Uses `flutter_gemma` package to run Gemma 4 model locally
- No internet required after initial model download
- Complete privacy - images never leave the device
- Supports GPU acceleration for faster inference

### 2. **Multimodal Image Analysis**
- Gemma 4 E2B model with vision capabilities
- Analyzes images for endangered species identification
- Provides conservation status and information
- Works with camera photos

### 3. **Minimal Internet Usage**
- Only downloads model once (2.4GB)
- All inference happens locally
- Smart download with retry logic

### 4. **Cross-Platform Support**
- iOS (16.0+)
- Android (API 21+)
- Web
- macOS, Windows, Linux (desktop)

### 5. **User-Friendly Interface**
- Simple camera/gallery selection
- Real-time analysis progress
- Detailed results with conservation information
- Share and copy functionality

## Project Structure

```
mero/
├── lib/
│   ├── main.dart                    # App entry point
│   ├── app_constants.dart           # Constants and configuration
│   ├── services/
│   │   ├── model_service.dart       # Gemma model management
│   │   └── permission_service.dart  # Permission handling
│   ├── pages/
│   │   ├── home_page.dart           # Main screen
│   │   ├── result_page.dart         # Analysis results
│   │   └── settings_page.dart       # App settings
│   ├── utils/
│   │   └── image_utils.dart         # Image processing helpers
│   └── widgets/
│       └── loading_overlay.dart     # Loading indicators
├── pubspec.yaml                     # Dependencies
├── .env                            # Environment variables
├── README.md                       # Documentation
├── BUILD_INSTRUCTIONS.md           # Build guide
├── TESTING.md                      # Testing guide
├── ANALYSIS_PROMPT.md              # Prompt engineering
└── assets/                         # App assets
```

## Technical Implementation

### Model Configuration
- **Model**: Gemma 4 E2B (2.4GB, int4 quantized)
- **Format**: `.litertlm` (LiteRT-LM format)
- **Source**: HuggingFace `litert-community/gemma-4-E2B-it-litert-lm` pinned to Apr 1 revision `7fa1d78473894f7e736a21d920c3aa80f950c0db`
- **Capabilities**: Multimodal (text + image), 1024 token context

### Prompt Engineering
The app uses carefully crafted prompts for accurate species identification:

```dart
systemInstruction: '''
You are an expert wildlife biologist and conservationist...
1. Identify the species if possible
2. Determine conservation status
3. Provide IUCN Red List category
4. Share interesting facts
5. Suggest conservation actions
''';
```

### State Management
- Uses `Provider` for state management
- `ModelService` handles model lifecycle
- Reactive UI updates with `ChangeNotifier`

### Image Processing
- Automatic image compression (1024x1024 max)
- Format detection and conversion
- Memory-efficient handling

## Platform Requirements

### iOS
- Minimum iOS 16.0
- Camera and photo library permissions
- File sharing enabled in Info.plist

### Android
- Minimum API 21 (Android 5.0)
- OpenGL support for GPU acceleration
- Runtime permissions for camera/storage

### Web
- MediaPipe GenAI library via CDN
- WebAssembly support
- Browser storage for model caching

### Desktop
- Platform-specific GPU drivers
- LiteRT-LM format models
- JVM gRPC server for inference

## Dependencies

### Core AI
- `flutter_gemma: ^0.10.0` - On-device Gemma inference

### UI & Utilities
- `camera: ^0.10.0` - Camera access
- `image_picker: ^1.0.0` - Image selection
- `permission_handler: ^11.0.0` - Permission management
- `provider: ^6.1.0` - State management
- `url_launcher: ^6.2.0` - External URL opening

## Setup Instructions

1. **Install Flutter** (3.0.0+)
2. **Clone project** and install dependencies:
   ```bash
   flutter pub get
   ```
3. **Platform setup** (see BUILD_INSTRUCTIONS.md)
4. **Run app**:
   ```bash
   flutter run
   ```
5. **Download model** on first launch

## Performance Considerations

### Memory Usage
- Model: ~2.4GB storage, ~500MB RAM during inference
- Images: Compressed to 1024x1024 max
- Cache: Managed by `flutter_gemma`

### Inference Speed
- GPU: 20-30 seconds per image
- CPU: 40-60 seconds per image
- Depends on device capabilities

### Battery Impact
- High during inference
- Minimal during idle
- Recommendation: Use while charging for extended analysis

## Privacy & Security

### Data Protection
- **No image uploads**: All processing local
- **No data collection**: No analytics or tracking
- **Model local**: AI model stays on device
- **Permissions**: Only camera/photo library access

### Security Features
- No external API calls after model download
- Local file storage only
- Permission-based access control
- Secure model validation

## Testing

### Automated Tests
- Unit tests for services and utilities
- Widget tests for UI components
- Integration tests for full workflows

### Manual Testing
- Model download and installation
- Camera and gallery functionality
- Species identification accuracy
- Offline functionality
- Error handling and recovery

## Future Enhancements

### Planned Features
1. **Species database**: Local database of endangered species
2. **Location integration**: GPS-based habitat information
3. **Community reporting**: Share sightings with conservation groups
4. **Multiple models**: Smaller models for faster inference
5. **Batch processing**: Analyze multiple images at once

### Performance Improvements
1. **Model optimization**: Further quantization (int2, binary)
2. **Caching**: Results cache for repeated images
3. **Background processing**: Analyze images in background
4. **Progressive loading**: Stream analysis results

## Contributing

1. Fork the repository
2. Create feature branch
3. Implement changes with tests
4. Submit pull request

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- **Google Gemma team** for the open model
- **DenisovAV** for `flutter_gemma` package
- **Conservation organizations** for species data
- **Flutter community** for tools and support

---

*This project demonstrates the potential of on-device AI for conservation technology. By making species identification accessible and private, we can empower more people to participate in wildlife conservation.*
