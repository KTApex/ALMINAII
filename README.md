<div align="center">

# 🔐 VpnHide

### *Calculator & VPN Masked Vault App*

A fully functional iOS **VPN Status & Network Utility** app that secretly hides photos, videos, and private notes behind a realistic VPN interface.

![iOS](https://img.shields.io/badge/iOS-16.0+-000000?style=for-the-badge&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.0-F05138?style=for-the-badge&logo=swift&logoColor=white)
![Xcode](https://img.shields.io/badge/Xcode-15+-147EFB?style=for-the-badge&logo=xcode&logoColor=white)
![CryptoKit](https://img.shields.io/badge/AES--256--GCM-Encrypted-00C853?style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge)

---

</div>

## ✨ Features

### 🎭 Disguise (Front Interface)

| Feature | Description |
|---------|-------------|
| 🛡️ **Realistic VPN & Network Tools UI** | Functional Speed Test, Ping Test, Wi-Fi Analyzer, and VPN Toggle |
| 🔑 **Hidden Entry** | Long-press the VPN Shield icon for **3 seconds** to trigger the secret PIN screen |
| 📩 **Disguised Notifications** | All system alerts appear as routine network alerts ("VPN Connection Optimized", "Wi-Fi Security Scan Complete") — never vault activity |
| 🕵️ **Stealth Mode** | App looks like a normal VPN utility — nothing suspicious on the surface |

### 🔒 Secret Vault (Unlocked Mode)

- **4/6-digit PIN** + **Face ID / Touch ID** (LocalAuthentication)
- **Photo & Video Vault:**
  - 📅 **Date-grouped grid** (Today / Yesterday / Month / Year) with clean headers
  - 🗂️ **Album & Category system** (Personal, Documents, Favorites + custom)
  - 🔀 **Sort** (Date Added / File Size / Name) and **Filter** (Photos / Videos)
  - ✅ **Multi-select mode** (long-press to enter)
  - 📥 **PhotosPicker** import with video playback support
- **Fully Customizable Auto-Slideshow:**
  - ⏱️ **Speed / Timer Control** — Fast (2s), Normal (3s), Slow (5s), Very Slow (10s)
  - 🎞️ **Transition Models** — Slide, Smooth Crossfade, Ken Burns Zoom, Flip/Cube
  - 🎬 **Smart Media Playback** — Videos auto-play, pause the photo timer, and auto-advance only on completion (`AVPlayerItemDidPlayToEndTime`)
  - 🎛️ **Control Overlay** — translucent Play/Pause, speed picker, transition switcher, live progress bar
- **AES-GCM Encryption** (CryptoKit) — files stored in Application Support, NOT the photo library
- **Panic Mode / Decoy Vault** — alternate PIN opens a clean fake photo vault
- **Intruder Selfie (Break-in Alert)** — front camera silently captures after 3 failed attempts, stored in hidden Security Log
- **Emergency Face-Down / Shake Lock** — auto-locks and returns to VPN screen when device is flipped or shaken
- **Encrypted Cloud Backup** — AES-256 containers for Google Drive / iCloud with Manual + Auto (Wi-Fi + charging) modes
- **Share Sheet** — decrypted media temporarily cached, native `UIActivityViewController`, cache auto-purged on close
- **In-App Private Camera** — capture photos/videos directly into the vault (never touches Camera Roll)
- **Auto-Delete Import** — optionally remove originals from public Photos after encryption
- **Trash / Recycle Bin** — 30-day retention before permanent purge
- **Obfuscated Storage Reporting** — displays "Network Cache: ~14 MB" instead of real vault size

### 🔐 Security Architecture

| Component | Technology |
|-----------|-----------|
| 🔒 File Encryption | CryptoKit AES-GCM (256-bit) |
| 🔑 PIN Storage | Keychain Services (salted SHA-256 hash) |
| 💾 Media Storage | Application Support directory (encrypted) |
| 👤 Biometrics | LocalAuthentication (Face ID / Touch ID) |
| 📸 Intruder Capture | AVCapturePhotoOutput (silent front-camera) |
| 📡 Motion Lock | CoreMotion + UIDevice orientation |
| ☁️ Cloud Backup | AES-256 container → Google Drive / iCloud |
| 🧹 Share Cache | Temp dir auto-purged on share sheet close |

---

## 📁 Project Structure

```
VpnHide/
├── project.yml                          # XcodeGen config (generates .xcodeproj)
├── .github/
│   └── workflows/
│       └── build-ipa.yml               # GitHub Actions auto-build pipeline
├── VpnHide/
│   ├── VpnHideApp.swift                # App entry point + root view routing
│   ├── Models/
│   │   └── VaultItem.swift             # Vault media model
│   ├── Managers/
│   │   ├── CryptoManager.swift         # AES-GCM encryption/decryption
│   │   ├── KeychainManager.swift       # Keychain PIN/key storage
│   │   ├── SecurityManager.swift       # Intruder selfie + face-down/shake lock + storage disguise
│   │   ├── CloudBackupManager.swift    # AES-256 cloud backup (manual + auto sync)
│   │   ├── VaultSessionManager.swift   # PIN, FaceID, panic mode state
│   │   └── VaultStorageManager.swift   # Encrypted file storage + trash + temp cache
│   ├── Views/
│   │   ├── VPNFrontView.swift          # VPN mask UI + speed/ping/wi-fi tools + secret trigger
│   │   ├── PasscodeView.swift          # PIN entry + FaceID + intruder lockout
│   │   ├── MediaVaultView.swift        # Date-grouped grid + albums + share + camera + trash
│   │   ├── MediaViewerView.swift       # Full-screen single media viewer (zoom + video)
│   │   ├── SlideshowView.swift         # Customizable auto-slideshow (speed, transitions, video sync)
│   │   ├── PrivateCameraView.swift     # In-app camera (photos + videos)
│   │   ├── TrashView.swift             # 30-day recycle bin
│   │   ├── VaultSettingsView.swift     # Panic PIN, biometrics, backup, security log
│   │   ├── DecoyVaultView.swift        # Fake/panic vault
│   │   └── Components/
│   │       ├── MediaThumbnailView.swift # Thumbnail cell
│   │       └── ShareSheet.swift         # UIActivityViewController bridge + temp cache purge
│   └── Assets.xcassets/                # App icon + accent color
```

---

## 🚀 Quick Start (Local Development)

### Prerequisites

- 🖥️ macOS with **Xcode 15+**
- 📦 [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for project generation)

### 1. Install XcodeGen

```bash
brew install xcodegen
```

### 2. Generate the Xcode Project

```bash
cd VpnHide
xcodegen generate
```

### 3. Open & Run

```bash
open VpnHide.xcodeproj
```

- Select your simulator/device
- Press **⌘R** to run

---

## 🤖 GitHub Actions Auto-Build (CI/CD)

### 1. Create a GitHub Repository

```bash
git init
git add .
git commit -m "Initial commit: VPN Masked Vault App"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/VpnHide.git
git push -u origin main
```

### 2. Trigger the Build

The workflow runs automatically on:

- **Push** to `main`/`master`
- **Pull Request** to `main`/`master`
- **Manual trigger** — go to `Actions` tab → `Build IPA` → `Run workflow`

### 3. Download the .ipa

1. Go to the **Actions** tab in your GitHub repo
2. Click the latest successful run
3. Scroll to **Artifacts** section
4. Download **`VpnHide-unsigned-ipa`**

---

## 📱 Installing the .ipa on iPhone

### Option A: AltStore (Recommended)

1. Install [AltStore](https://altstore.io) on your iPhone (requires PC/Mac)
2. Connect iPhone to computer, open AltStore
3. Drag `VpnHide.ipa` into AltStore
4. Enter your Apple ID when prompted
5. App installs — go to **Settings → General → VPN & Device Management** → Trust

### Option B: Sideloadly

1. Download [Sideloadly](https://sideloadly.io) for Windows/Mac
2. Connect iPhone, drag `VpnHide.ipa` into Sideloadly
3. Enter your Apple ID
4. Click **Start** — app installs automatically

### Option C: TrollStore (Jailbroken/arm64e devices)

1. Install [TrollStore](https://github.com/opa334/TrollStore)
2. Open TrollStore → `+` → select `VpnHide.ipa`
3. App installs permanently, no re-signing needed

---

## 🔑 Usage Guide

### First Launch

1. App opens as **VPN Status** screen
2. **Long-press the shield icon (3 seconds)** → PIN setup screen appears
3. Set your **4/6-digit vault PIN**
4. (Optional) Set a **Panic PIN** in settings

### Unlocking the Vault

- **Long-press shield** → enter PIN → vault opens
- **Face ID / Touch ID** available after first unlock

### Panic Mode

- Enter your **Panic PIN** instead of the real PIN
- Opens a **fake photo vault** with decoy content
- Real vault stays hidden

### Managing Media

1. In vault, tap **+** to import photos/videos
2. **Long-press** any item → multi-select mode
3. Select multiple items → **Start Slideshow** button appears
4. In the slideshow:
   - **Speed picker** (bottom-left) — Fast 2s / Normal 3s / Slow 5s / Very Slow 10s
   - **Transition picker** (bottom-right) — Slide / Crossfade / Ken Burns / Flip
   - **Play/Pause** (center) — pauses the photo timer and video playback
   - **Progress bar** — live progress for the current photo or video
   - Videos auto-play on arrival and auto-advance only when playback completes
5. **Delete** selected items from the action bar

---

## 🔐 Security Notes

- All media is encrypted with **AES-256-GCM** before touching disk
- PINs stored as **salted SHA-256 hashes** in Keychain
- Files stored in **Application Support** — invisible to Photos app
- **Panic PIN** provides plausible deniability
- App icon/name shows as VPN utility — no vault traces

---

## 🛠 Troubleshooting

| Issue | Fix |
|-------|-----|
| `xcodegen: command not found` | `brew install xcodegen` |
| Build fails on GitHub | Check Xcode version in workflow (line 20-23) |
| Face ID not working | Enable in Settings → Face ID & Passcode |
| Can't install .ipa | Ensure device is iOS 16+ and trusted in Settings |
| Vault empty after reinstall | Data is encrypted & deleted with app — backup manually |

---

## 📄 License

**MIT License** — free to use, modify, and distribute.

---

## ⚠️ Disclaimer

This app is for **personal privacy protection** only. Users are responsible for complying with all applicable laws regarding data storage and privacy in their jurisdiction.

---

<div align="center">

**Made with ❤️ for privacy**

</div>