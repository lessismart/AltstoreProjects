# Box Finder for iPhone & iPad (Swift / SwiftUI)

Native iOS & iPadOS implementation of **Box Finder**, interoperable with the Android 2.2.0 (`com.lessy.boxfinder.gemma`) and Raspberry Pi (`box-finder-sync.php`) baselines.

All core inventory management, instant search, photo storage, QR label generation/scanning, and JSON backups work **completely offline** without any AI model, API key, or Pi server connection.

---

## Verified Toolchain & Dependency Choices

- **Xcode / iOS SDK (verified on GitHub Actions `macos-latest`):** Xcode 26.6 / iOS SDK 26.5
- **Deployment Target:** iOS / iPadOS `16.0` (Universal `TARGETED_DEVICE_FAMILY: "1,2"`, Swift 5 with Swift Concurrency + `@MainActor` UI boundary)
- **Project Generator:** XcodeGen (`project.yml`)
- **Offline Gemma Runtime:** Google AI Edge **`LiteRT-LM` `v0.19.1`** (`https://github.com/google-ai-edge/LiteRT-LM.git`, Apache-2.0 license), using its prebuilt `CLiteRTLM.xcframework` (`ios-arm64` + `ios-arm64-simulator`)
- **System Frameworks Only (no extra third-party deps):**
  - `SQLite3` (`libsqlite3.tbd`) for transactional local database & schema migrations
  - `zlib` (`libz.tbd`) for Pi sync gzip compression/decompression
  - `CryptoKit` for SHA-256 photo/bundle/revision digests
  - `Security` (Apple Keychain) for API keys and Pi pairing tokens
  - `CoreImage`, `Vision`, `AVFoundation`, `PhotosUI`, `UIKit` for QR generation/scanning, upright image normalization, printing, and file pickers

---

## Folder Structure

```text
BoxFinder/
├── project.yml                         # XcodeGen specification (BoxFinder + BoxFinderTests)
├── BoxFinder/
│   ├── App/                            # BoxFinderApp, AppState (MainActor coordinator)
│   ├── Models/                         # Codable / Sendable domain models
│   ├── Storage/                        # SQLiteBoxDatabase, PhotoFileStore, PhotoAnnotationStore, KeychainVault, BackupService
│   ├── Sync/                           # GzipCodec, SyncURLValidator, SyncEngine (3-way merge & hashes)
│   ├── AI/                             # AiJsonParser, PhotoGeometry, PhotoAiSettings, OnlineVisionClient, ModelStore, LiteRTLMRuntime, PhotoAiCoordinator
│   ├── QR/                             # QRCodeService, QRScannerSheet (camera + photo + manual code)
│   ├── Views/                          # Adaptive iPhone/iPad SwiftUI views & AnnotatedPhotoCanvas
│   └── Resources/Assets.xcassets/      # AppIcon (1024x1024 RGB) & AccentColor
├── BoxFinderTests/                     # XCTest suite covering DB, Backup, Sync, AI, Geometry, QR & ModelStore
└── Examples/                           # Redacted pairing, backup & AI JSON examples
```

---

## Building on a Mac

1. Install **XcodeGen** if needed:
   ```bash
   brew install xcodegen
   ```
2. Generate `BoxFinder.xcodeproj` and resolve packages (`GIT_LFS_SKIP_SMUDGE=1` is required by `LiteRT-LM`):
   ```bash
   cd BoxFinder
   xcodegen generate
   GIT_LFS_SKIP_SMUDGE=1 xcodebuild -resolvePackageDependencies -project BoxFinder.xcodeproj -scheme BoxFinder
   ```
3. Open `BoxFinder.xcodeproj` in Xcode, pick your signing team under **Signing & Capabilities** (for physical iPhone/iPad deployment), and run on Simulator or device (`Cmd + R`), or run tests (`Cmd + U`).

### Sideloading with AltServer (from GitHub Actions CI)
The workflow `.github/workflows/build-boxfinder.yml` runs the `BoxFinderTests` suite on an iOS Simulator and compiles an unsigned `BoxFinder.ipa` artifact (`BoxFinder-ipa`). Download `BoxFinder.ipa` to a pure-ASCII path (e.g., `C:\Users\Public\BoxFinder.ipa`) and sideload via **Left Shift + Click AltServer → Sideload .ipa...**.

---

## Permissions Explained

- **Camera (`NSCameraUsageDescription`):** Used only when you tap *Take photo* inside a box or open *Scan QR* to read a label.
- **Photo Library (`NSPhotoLibraryUsageDescription` / `NSPhotoLibraryAddUsageDescription`):** Used when choosing existing box/QR photos or exporting a generated QR label image.
- **Local Network (`NSLocalNetworkUsageDescription` + `NSBonjourServices: _http._tcp`):** Used strictly for manual **Sync now** with your Raspberry Pi on home Wi-Fi (`pi-usbserver.local` / `192.168.x.x` / `10.x.x.x` on port `8000`).
- **Network Security (`NSAppTransportSecurity`):** `NSAllowsLocalNetworking = true` permits local `http://` Pi sync while keeping strict HTTPS enforced (`NSAllowsArbitraryLoads = false`) for all online providers and model downloads.

---

## Pi Pairing & Sync Protocol

- Default URL: `http://pi-usbserver.local:8000/box-finder-sync.php`
- Import a pairing JSON file matching `Examples/pairing.example.json` (`url` + 64-character hex `token`). The token is stored in Apple Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and excluded from backups.
- **Manual 3-way merge:** Uses the exact box-bundle SHA-256 algorithm and `X-Box-Sync-Key` + gzip `GET`/`POST` protocol of `SyncEngine.java` and `box-finder-sync.php`.
- **Conflict resolution:** Edits to different boxes merge cleanly; edits to the same box on both devices prompt you to keep either this device's or the Pi's version (never silent last-write-wins).
- **Crash recovery:** Before modifying local data after a remote Pi commit succeeds, a temporary pre-sync recovery file is staged until local SQLite replacement succeeds.

---

## AI Providers, Offline Gemma & Privacy

- **Online Providers (OpenRouter & Google Gemini):**
  - OpenRouter defaults to `google/gemini-2.5-flash` (with quick-pick for `qwen/qwen3.7-flash` matching the Pi service) and lets you browse live vision models (`input: image`, `output: text`) or enter any model ID.
  - Google Gemini defaults to `gemini-2.5-flash`.
  - API keys are stored only in Apple Keychain, never sent across HTTP redirects, and excluded from backups.
  - Upload confirmation is enabled by default; connection checks never upload box photos.
- **Offline Gemma (`LiteRT-LM v0.19.1`):**
  - Import a vision-capable `.litertlm` file (such as `gemma-4-E2B-it-litert-lm` or `gemma-3n-E2B-it-litert-lm`) from the Files app or download directly over HTTPS with progress, cancellation, free-storage checks, and optional SHA-256 verification.
  - **Honest Memory Limitations:** Multi-gigabyte vision models can exceed iOS Jetsam RAM limits on devices with < 6 GB RAM. `LiteRTLMRuntime` serializes inference, caps context/image resolution (`384px` / `1024` tokens on < 6 GB RAM, single-photo batching with item deduplication), cancels active inference on `didReceiveMemoryWarningNotification`, and exposes a CPU toggle if GPU Metal allocation fails. A model that passes a text readiness check may still exceed memory during multi-photo vision inference on older hardware.
- **Ask Gemma:** Runs strictly against your local offline Gemma model using recorded inventory text (reporting `Searched X of Y boxes` when context bounds truncate long lists) and never invents unrecorded box codes.

---

## Backups & Security Warnings

- Format: `box-finder-android-v1` UTF-8 JSON containing `boxes`, `items`, `photos` (base64 JPEG), and optional `detections` overlay metadata.
- **Unencrypted Export Warning:** Exported backup JSON files contain **unencrypted** inventory text and JPEG photos. Store them safely. API keys, Pi pairing tokens, and `.litertlm` model weights are never exported.
- Imports preview counts and require explicit confirmation, stage and validate every filename and JPEG before replacing local records transactionally, and remain compatible with older backups lacking `detections`.
