# Translate the Screenshot

Translate the Screenshot is a lightweight macOS menu bar translation and OCR tool built with Swift, SwiftUI, AppKit, Vision, and Keychain.

The app is packaged as `TTS.app` and runs as a menu bar utility.

## Features

- Selection translation with `Option + D`
- Input translation with `Option + A`
- Screenshot translation with `Option + S`
- Screenshot OCR with `Shift + Option + S`
- Silent screenshot OCR with `Option + C`
- Floating translation panel that does not steal focus
- History and favorites
- Configurable translation providers
- API keys stored in Keychain
- Accessibility and Screen Recording permission guidance
- Local Apple Vision OCR
- macOS `.app` packaging with custom app and menu bar icons

## Translation Providers

Implemented providers include:

- OpenAI-compatible API
- GLM-4-Flash
- SiliconFlow
- DeepL
- Google Cloud Translation
- Microsoft Translator / Bing
- Baidu Translate
- Tencent Cloud TMT
- Volcengine Translate
- MyMemory free test provider

## Build For Development

```sh
swift build
swift run
```

After launch, TTS appears in the macOS menu bar.

## Build The App Bundle

```sh
scripts/build_app.sh
```

The generated app is:

```text
build/Release/TTS.app
```

Install it into Applications:

```sh
rm -rf /Applications/TTS.app
cp -R build/Release/TTS.app /Applications/
open /Applications/TTS.app
```

## Xcode Build

If full Xcode is installed:

```sh
xcodebuild -project tts.xcodeproj -scheme tts -configuration Release build
```

## Permissions

TTS needs macOS permissions for the following features:

- Accessibility: read selected text and use the protected clipboard fallback
- Screen Recording: screenshot OCR and screenshot translation

If permissions look enabled but TTS still reports missing permission, fully quit TTS and reopen `/Applications/TTS.app`. macOS tracks permissions by the concrete app bundle identity and path.

## Notes

This repository intentionally does not commit build output, `.app` bundles, local caches, or secrets.
