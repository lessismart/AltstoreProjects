# AltStore Windows Setup & SwiftUI iPad Test App

This repository contains:
- A native SwiftUI iPad/iPhone test app (`AltStoreTestApp`) built with **XcodeGen** (`project.yml`).
- A GitHub Actions workflow (`.github/workflows/build-ipa.yml`) that compiles an unsigned `AltStoreTestApp.ipa` on `macos-latest`.
- A Windows diagnostic script (`scripts/check-altstore-setup.ps1`) to verify desktop iCloud, desktop iTunes, AltServer, Apple services, and the USB-connected iPad.

---

## 1. Verify Windows AltStore Prerequisites

Run the verification script from PowerShell:

```powershell
.\scripts\check-altstore-setup.ps1
```

All checks should pass (no Microsoft Store versions of iTunes or iCloud, desktop Apple support directories present, `Apple Mobile Device Service` and `Bonjour Service` running, `AltServer` running, and iPad detected on USB).

> If you just installed iCloud or iTunes and `Apple Mobile Device Service` is stopped or asks for a restart, reboot Windows once and re-run the check script.

---

## 2. Pair the iPad with iTunes

1. Connect the iPad to this PC over USB and unlock it.
2. Open **iTunes** (the desktop version installed in `Program Files\iTunes`).
3. If prompted on both the PC and the iPad, tap **Trust** on the iPad and enter your passcode.
4. Click the small **iPad icon** near the top-left of iTunes.
5. Under **Summary → Options**, check **Sync with this iPad over Wi-Fi** and click **Apply**.

---

## 3. Install AltStore onto the iPad

1. Ensure **AltServer** is running (check the diamond-shaped icon in the Windows system tray near the clock; allow it through Windows Defender Firewall for Private networks if prompted).
2. Left-click the **AltServer** tray icon → **Install AltStore** → select your **iPad**.
3. Sign in with your Apple ID when prompted by AltServer.
4. Once AltStore finishes installing on the iPad:
   - **Trust the Developer Certificate:** On the iPad, open **Settings → General → VPN & Device Management**, tap your Apple ID under *Developer App*, and tap **Trust**.
   - **Enable Developer Mode (iPadOS 16+):** On the iPad, open **Settings → Privacy & Security**, scroll down to **Developer Mode**, toggle it **On**, restart the iPad when prompted, then confirm **Turn On** after reboot.
5. Open **AltStore** on the iPad and sign in with the same Apple ID in **Settings** inside AltStore.

---

## 4. Build `AltStoreTestApp.ipa` with GitHub Actions

1. Create a new repository on GitHub (public or private) and push this local `main` branch:
   ```powershell
   git remote add origin https://github.com/<your-username>/<your-repo>.git
   git push -u origin main
   ```
2. Open the **Actions** tab on GitHub and wait for the **Build Unsigned iOS IPA** workflow to finish.
3. Download the **`AltStoreTestApp-ipa`** artifact (or push a tag like `v1.0.0` to also attach `AltStoreTestApp.ipa` to a GitHub Release) and extract `AltStoreTestApp.ipa`.

---

## 5. Sideload the Test App onto the iPad

Choose either method:

- **Option A — Direct Sideload via AltServer (PC):**
  1. Keep your iPad unlocked and connected (USB or same Wi-Fi).
  2. Hold down **Left Shift** and click the **AltServer** icon in the Windows system tray.
  3. Click **Sideload .ipa...**, select your iPad, and choose `AltStoreTestApp.ipa`.
- **Option B — Via AltStore on the iPad:**
  1. Transfer `AltStoreTestApp.ipa` to your iPad (e.g., iCloud Drive, Files, or USB file sharing).
  2. Open **AltStore** on the iPad → **My Apps** → tap **`+`** in the top-left → select `AltStoreTestApp.ipa`.

Launch **AltStore Test** on the iPad to verify bundle ID, device diagnostics, live viewport dimensions, and persistent `@AppStorage` controls.
