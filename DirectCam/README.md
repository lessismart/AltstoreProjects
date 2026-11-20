# DirectCam — Standalone Direct Camera Viewer & Admin (iPhone & iPad)

Native SwiftUI iPhone & iPad application that connects **directly** over local Wi-Fi to Xiongmai / iCSee and ONVIF IP cameras — requiring **zero Raspberry Pi** and **zero cloud account**.

## Direct Protocols Supported
- **Pure-Swift RTSP + VideoToolbox (`:554`):** Direct interleaved TCP RTSP (`OPTIONS` → `DESCRIBE` with Basic/Digest auth → `SETUP` → `PLAY`), RFC 7798 **HEVC (H.265)** & RFC 6184 **H.264** RTP depacketization, `G.711` A-law/μ-law receive-only audio (`AudioStreamPlayer`), hardware `VTDecompressionSession` + `AVSampleBufferDisplayLayer` rendering, snapshots, and local `.mp4` recording.
- **ONVIF SOAP (`:8899`) + WS-Discovery (`239.255.255.250:3702`):** LAN discovery, WS-UsernameToken SHA-1 authentication, device info, media profiles, stream/snapshot URIs, clock sync, remote reboot, imaging & IR Cut filter controls, PTZ D-Pad + Presets, and PullPoint motion event subscription.
- **Xiongmai DVRIP (`:34567`):** Native 20-byte LE TCP framing + Sofia MD5 password hashing for MicroSD storage info & formatting, MicroSD recording query & direct `.mp4` download (`OPFileQuery` / `OPPlayBack`), H.265/H.264 encoder settings, OSD title/time overlays, camera motion & humanoid detection, spotlight control, password change, and **LAN-Only Cloud P2P Lockdown (`NatEnable = false`)**.
- **On-Device Vision Kiosk Monitor:** Runs Apple `VNDetectHumanRectanglesRequest` + `VNRecognizeAnimalsRequest` locally on decoded frames with bounding boxes, chime, local banner notifications, cooldown gating, auto-recorded `.mp4` alert clips, and idle-screen lock override.
- **Strict Security Defaults:** Camera passwords live exclusively in Apple Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); exported profile JSONs never include passwords; zero microphone entitlement/capture (`No Two-Way Audio`).

## Building & Sideloading
Pushes under `DirectCam/` trigger `.github/workflows/build-directcam.yml` (`macos-latest`, `XcodeGen`, iOS Simulator `DirectCamTests`, and unsigned ARM64 `DirectCam.ipa` artifact). Download `DirectCam.ipa` to a pure-ASCII folder (e.g. `C:\Users\Public\DirectCam.ipa`) and sideload via **Left Shift + Click AltServer → Sideload .ipa...**.
