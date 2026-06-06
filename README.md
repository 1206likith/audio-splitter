# Audio Splitter App

A cross-platform Flutter application that acts like a digital audio splitter - streaming audio to multiple devices simultaneously.

## Getting Started

### Prerequisites
- Flutter SDK (3.10.0 or higher)
- Dart SDK (3.0.0 or higher)

### Installation

1. **Install Flutter** from https://flutter.dev/docs/get-started/install

2. **Clone or navigate to the project**:
   ```bash
   cd C:\Users\likit\audio_splitter_app
   ```

3. **Get dependencies**:
   ```bash
   flutter pub get
   ```

4. **Run the application**:
   ```bash
   flutter run -d windows    # For Windows
   flutter run -d chrome     # For Web
   flutter run -d android    # For Android (with device connected)
   ```

## Features

- **Host Mode**: Transform your device into an audio broadcasting hub
- **Client Mode**: Connect to host devices to receive audio streams
- **Cross-Platform**: Works on Windows, Web, Android, and iOS
- **Modern UI**: Beautiful Material Design 3 interface

## Current MVP Status

- Runtime-verified host/client app flow
- Web build verified (`flutter build web --no-wasm-dry-run`)
- Capture source support is currently limited to **microphone**
- Advanced sources (system audio, media files, remote stream ingest) are not yet production capture paths

For a deployment checklist and verified environment requirements, see `RELEASE_READINESS.md`.

## How to Use

1. **Host Mode**: 
   - Select the "Host" tab
   - Click "Start Hosting" to begin broadcasting
   - Other devices can now connect to this host

2. **Client Mode**:
   - Select the "Client" tab  
   - Click "Connect" and enter the host's IP address
   - Enjoy synchronized audio from the host device

## Project Structure

```
audio_splitter_app/
├── lib/
│   └── main.dart          # Main application code
├── web/                   # Web platform files
├── windows/               # Windows platform files
├── android/               # Android platform files
├── pubspec.yaml           # Project configuration
└── README.md             # This file
```

## Supported Platforms

- ✅ Windows (Desktop)
- ✅ Web (Chrome, Edge)
- ✅ Android
- ✅ iOS (with macOS development environment)

## Development

This is a Flutter project. To extend functionality:

1. Add new features in `lib/main.dart`
2. Add dependencies in `pubspec.yaml`
3. Test on multiple platforms with `flutter run -d <platform>`

## Future Enhancements

- Real audio streaming implementation
- Bluetooth device support
- Advanced audio synchronization
- Performance monitoring
- Professional audio features

---

**Note**: This project is now an MVP with functional host/client plumbing and web build readiness. Some advanced capture/output capabilities are still under active development.
