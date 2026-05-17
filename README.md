<p align="center">
  <img
    src="android/app/src/main/res/mipmap-hdpi/ic_launcher.png"
    width="60"
    alt="Mero Logo"
  />
  <br/>
  <br/>
  <strong>Mero — Empowering the Guardians of Tomorrow</strong>
</p>

<p align="center"><em>"We can't protect what we don't recognize."</em></p>

<p align="center">
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.0%2B-02569B?logo=flutter" />
  <img alt="Platform" src="https://img.shields.io/badge/Platform-Android-lightgrey?logo=android" />
  <img alt="AI" src="https://img.shields.io/badge/AI-Gemma%204%20(On--Device)-4285F4?logo=google" />
  <img alt="Offline" src="https://img.shields.io/badge/Works-Offline-brightgreen" />
  <img alt="License" src="https://img.shields.io/badge/License-MIT-yellow" />
</p>

<br/>

Indonesia holds a significant percentage of the world's endangered species, but **students living on the frontlines** lack the internet access needed to identify them, limiting their ability to protect the environment. \
Mero addresses this gap leveraging **Gemma 4 AI model running locally on-device** to identify endangered species from images, delivering crucial conservation education entirely without connectivity.

---

## Features

- **On-Device AI** — Gemma 4 E2B runs entirely on your device; no data leaves your phone
- **Camera Integration** — Snap a photo and get an instant species identification
- **Conservation Info** — Learn about each species' conservation status and background
  - IUCN Conservation Status — Colour-coded badge (Least Concern → Critically Endangered) with full status detail for every identified species
  - Threats & Ecosystem Role — Understand why a species matters and what's putting it at risk
  - What You Can Do — Actionable conservation tips tailored to each species
- **Offline-First** — Internet is only needed once, for the initial model download (~2.4 GB)
- **Dual Language** — Full support for Bahasa Indonesia and English, switchable in-app

---

## Prerequisites

- **Flutter SDK** 3.0.0 or higher ([install guide](https://docs.flutter.dev/get-started/install))
- **Android**: A device or emulator with OpenGL ES 3.1+ support (required for GPU acceleration; falls back to CPU on unsupported devices)
- **Free storage**: At least 3 GB for the model and app

---

## Download  

Get the latest APK from [Releases](../../releases)  

---

## Model Details

<details>
<summary>Show details</summary>

| Property | Value |
|---|---|
| Model | Gemma 4 E2B |
| Size | ~2.4 GB (int4 quantized) |
| Format | `.litertlm` (LiteRT-LM) |
| Modality | Multimodal (text + image) |
| Context window | 4096 tokens |
| Source | [litert-community/gemma-4-E2B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) |

</details>

---

## Dependencies

| Package | Purpose |
|---|---|
| [`flutter_gemma`](https://pub.dev/packages/flutter_gemma) | On-device Gemma model inference |
| [`camera`](https://pub.dev/packages/camera) | Camera access |
| [`permission_handler`](https://pub.dev/packages/permission_handler) | Runtime permissions |
| [`provider`](https://pub.dev/packages/provider) | State management |

---

## Limitations

- **Model size**: A one-time ~2.4 GB download is required
- **Accuracy**: Identification quality depends on model training data; rare or visually similar species may be misidentified
- **Performance**: Inference speed varies by device — newer hardware will be significantly faster
- **Battery**: On-device AI inference is compute-intensive; expect higher battery usage during active identification

---

## Privacy

- All image analysis happens **locally on your device**
- Photos are never uploaded to any server
- The model runs fully offline after the initial download
- No personal data is collected or transmitted

---

## Contributing

Contributions are welcome! Here's how to get started:

1. Fork this repository
2. Create a feature branch: `git checkout -b feature/your-feature-name`
3. Make your changes and test on both Android and iOS if possible
4. Commit with a clear message: `git commit -m "feat: describe your change"`
5. Push and open a Pull Request

Please open an issue first for large changes so we can discuss the approach.

---

## Built With

- [flutter_gemma](https://pub.dev/packages/flutter_gemma) by DenisovAV
- [Google Gemma](https://ai.google.dev/gemma)

## Acknowledgments

- [Sirkula Indonesia](https://sirkulaindonesia.com/) ([@sirkulaindonesia](https://www.instagram.com/sirkulaindonesia/)) for their conservation mission and inspiration
- Conservation organizations around the world working to protect endangered species

---

## License

This project is licensed under the [MIT License](LICENSE).
