# ArchiveX

A ZArchiver-style archive manager for Android, built with Flutter. Browse your
device's storage, create and extract `.zip`, `.tar`, `.tar.gz`, `.tar.bz2`,
`.gz` and `.bz2` archives, and password-protect any file with real
AES-256-GCM encryption — all with an in-app debug log so you can see exactly
what the app is doing.

## Features

- **File browser** — navigate, search, multi-select, copy/move (cut+paste),
  rename, delete, create folders.
- **Archive creation** — zip / tar / tar.gz / tar.bz2, optionally encrypted.
- **Archive extraction** — zip / tar / tar.gz / tar.bz2 / gz / bz2, with
  **zip-slip (path traversal) protection**: any entry that would extract
  outside the target folder is skipped, not written.
- **Real encryption** — AES-256-GCM with a PBKDF2-HMAC-SHA256 key (310,000
  iterations) derived from your password, fresh random salt + nonce per file,
  and an authenticated header. Produces `.aes` files; wrong password or a
  tampered file is rejected before anything is written to disk.
- **Storage permission flow** — asks for "All files access" on Android 11+
  (falls back to classic storage permission on Android 10 and below), with a
  clear explanation screen and a re-check whenever you return to the app.
- **In-app debug log** — every operation (permissions, browsing, compress/
  extract/encrypt/decrypt jobs, errors) is timestamped, kept on screen, saved
  to a rotating log file, and copyable in one tap.
- **Background-safe** — every archive/crypto/file operation runs in a
  separate isolate via `Isolate.run`, so the UI never freezes on large files.

## Repository layout

```
archivex/
├── lib/main.dart                 # the entire app
├── pubspec.yaml                  # dependencies
├── .github/workflows/build.yml   # CI: builds a release APK on every push
├── scripts/patch_android.py      # patches the CI-generated android/ folder
└── .gitignore
```

Notice there is **no `android/` folder in the repo.** The GitHub Actions
workflow runs `flutter create --platforms=android .` fresh on every run to
generate it, then patches it (manifest permissions, app label, Gradle
settings) and restores `lib/` and `pubspec.yaml` on top. This means:

- You never get "missing android directory" / stale Gradle scaffold errors —
  there's nothing stale to go stale.
- The scaffold always matches the exact Flutter version the workflow pins,
  avoiding template/version mismatches.

## Building the APK with GitHub Actions (recommended, no local setup)

1. **Create a new GitHub repository** (public or private).
2. **Unzip this project** and push everything to that repo:
   ```bash
   unzip archivex.zip -d archivex
   cd archivex
   git init
   git add .
   git commit -m "ArchiveX"
   git branch -M main
   git remote add origin https://github.com/<you>/<your-repo>.git
   git push -u origin main
   ```
3. Go to the **Actions** tab of your repository on GitHub. The workflow
   ("Build ArchiveX APK") starts automatically on the push. You can also
   trigger it manually from Actions → Build ArchiveX APK → Run workflow.
4. Wait for the run to go green (first run: ~6–10 minutes while Gradle and
   the Android SDK components download; every run after that is much faster
   because Gradle's dependency cache, keyed on the Flutter version and
   `pubspec.yaml`, is restored automatically — this is also what protects you
   from Maven Central rate limits on repeat builds).
5. Open the completed run → **Artifacts** → download **archivex-apk**. It's a
   zip containing split APKs per CPU architecture (`app-arm64-v8a-release.apk`
   covers essentially every phone from the last several years;
   `app-armeabi-v7a-release.apk` covers older 32-bit devices;
   `app-x86_64-release.apk` is for emulators/x86 devices).
6. Copy the right APK to your phone and install it (you'll need to allow
   "install unknown apps" for whichever app you use to open the file).

## Building locally instead

If you have the Flutter SDK installed:

```bash
flutter create --platforms=android --org com.archivex --project-name archivex .
python3 scripts/patch_android.py
flutter pub get
flutter build apk --release --split-per-abi
```

The APKs land in `build/app/outputs/flutter-apk/`.

## About APK signing

Flutter's default template signs release builds with the **debug keystore**
(there's no release signing config in this project), which is fine for
installing on your own device but is not something you'd publish to the Play
Store. If you want a properly signed release build:

1. Generate a keystore: `keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`.
2. Add a `key.properties` file and a signing config to
   `android/app/build.gradle` (standard Flutter docs:
   https://docs.flutter.dev/deployment/android#signing-the-app).
3. In CI, store the keystore and its passwords as GitHub Actions secrets and
   write them to disk in a step before `flutter build apk`.

## Permissions

ArchiveX requests:

- `MANAGE_EXTERNAL_STORAGE` (Android 11+, the "All files access" toggle) —
  needed to browse and archive files anywhere on shared storage, not just the
  app's own sandbox.
- `READ_EXTERNAL_STORAGE` / `WRITE_EXTERNAL_STORAGE` (capped at SDK 32) as a
  fallback for Android 10 and below.

The permission screen explains this before asking, and there's an "Open app
settings" shortcut if you need to grant it manually.

## Encryption format (`.aes` files)

```
"AXE1" (4 bytes) | PBKDF2 iterations, u32 BE (4 bytes) | salt (16 bytes) |
nonce (12 bytes) | AES-256-GCM ciphertext | GCM authentication tag (16 bytes)
```

The 36-byte header is passed as authenticated additional data (AAD) to GCM,
so the header can't be tampered with independently of the ciphertext either.
Decryption verifies the tag before writing any output; a wrong password or a
corrupted file fails cleanly with no partial file left behind.

## Troubleshooting

- **A CI run fails on a dependency download** — re-run the job; the retry/
  timeout settings in `scripts/patch_android.py` (10 retries, 3-minute
  timeouts) and the Gradle cache already absorb almost all transient Maven
  Central / Google Maven hiccups, but a full outage can still occasionally
  need one re-run.
- **"All files access" toggle doesn't stick on some devices** — this is a
  vendor Android-skin quirk in the system settings screen, not the app; the
  in-app debug log (accessible from the permission screen and the main menu)
  will show whether the app sees the permission as granted after you return
  to it.
