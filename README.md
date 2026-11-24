# 404tunes

A music player for **Android and desktop** (Linux, Windows, macOS) that finds and streams songs from YouTube with
[yt-dlp](https://github.com/yt-dlp/yt-dlp). Everything runs inside the app: **no server**. yt-dlp ships with the app.

- Search songs and playlists, play, seek, shuffle, repeat, queue (reorder, play next, add)
- Playlists, per profile (save a YouTube playlist, or build your own from search)
- Local profiles: the first launch creates the **admin**; the admin adds other profiles, each with its own PIN, playlists and saved queue
- Android: media notification, lock-screen and headset controls, background playback
- Optional offline cache (size limit, least-recently-used cleanup): cached songs play without internet
- yt-dlp updates itself (Android: daily in the background; desktop: Settings → Update), optional `cookies.txt` for when YouTube asks "confirm you're not a bot"
- Desktop shortcuts: `Space` play/pause (not while typing), `Ctrl+←` / `Ctrl+→` previous / next

> **YouTube's terms:** playing YouTube audio outside YouTube's own player goes against its terms of service. This is a personal-use
> tool; it can't be published on Google Play for that reason, so Android is a sideloaded APK.
>
> **Profiles are a lock, not encryption.** They keep people's playlists apart on one device. The database file is not encrypted.

## How it works

```
Flutter UI
 ├─ YtDlpService          search / playlist / resolve / download, caches, retries (shared Dart code)
 │    └─ YtBackend        desktop: runs the bundled yt-dlp binary    android: youtubedl-android (Python + yt-dlp) via a Kotlin plugin
 ├─ PlayerController      queue + just_audio (desktop: libmpv via media_kit; Android: ExoPlayer) + audio_service
 ├─ SQLite                profiles, playlists, saved queue
 └─ CacheManager          optional offline cache
```

**Finding a playable link** (the part YouTube keeps changing, see `lib/yt/ytdlp_service.dart`):
1. yt-dlp **without** a JavaScript runtime (~2 s). yt-dlp then uses a YouTube client whose links need no challenge. The link is checked with a 2-byte
   `Range` request.
2. If that fails (or yt-dlp finds no audio), yt-dlp again **with** the bundled [quickjs-ng](https://github.com/quickjs-ng/quickjs) runtime to solve YouTube's
   challenges (~10 s on a PC; slower on a phone).
3. The next song in the queue is looked up while the current one plays, so the next one starts instantly.

(deno was tried as the runtime and rejected: deno 2.9.8 produced challenge answers that YouTube answered with HTTP 403, quickjs-ng's were accepted.)

## Build

Needs the [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.x) and, for Android, the Android SDK (platform 35, build-tools 35).

```bash
tool/fetch_binaries.sh          # downloads yt-dlp + quickjs for desktop (assets/bin/) and quickjs for Android (jniLibs/)
flutter pub get

flutter run -d linux            # or windows / macos
flutter build linux --release   # desktop build: needs clang, cmake, ninja, GTK 3 and libmpv dev packages on Linux
flutter build apk --release --split-per-abi   # Android APKs (arm64-v8a is what most phones need)
```

Linux needs `libmpv` at runtime too (`sudo apt install libmpv2`, or `libmpv-dev` to build).
The Windows and macOS binaries are fetched by the script, but those platforms can only be built on Windows / macOS.
macOS: the bundled quickjs is the Apple-silicon build.

### Release signing (Android)

Release APKs are signed with the key named in `android/key.properties` (not in git, together with the `.jks` keystore). Without that file the
release build falls back to the debug key, so a fresh clone still builds. To make your own key:

```bash
keytool -genkeypair -keystore android/my-release.jks -storetype PKCS12 -alias myalias -keyalg RSA -keysize 4096 -validity 36500
# android/key.properties:
#   storePassword=...   keyPassword=...   keyAlias=myalias   storeFile=my-release.jks   (path relative to android/)
```

Keep the keystore and its password backed up: an app can only be updated in place by APKs signed with the same key.

### Releases (GitHub Actions)

`.github/workflows/release.yml` builds Android, Linux, Windows and macOS (Apple silicon) and attaches them to a release when you push a version tag:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

A tag build refuses to run without the signing secrets, so debug-signed APKs can't be published by accident. Add them once under
Settings → Secrets and variables → Actions, or with the `gh` CLI:

```bash
base64 -w0 android/404tunes-release.jks | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD        # the password in android/key.properties
gh secret set ANDROID_KEY_ALIAS --body tunes404
```

"Run workflow" on the Actions tab builds everything for testing and keeps the files as artifacts without making a release.
The Windows and macOS builds are unsigned: Windows SmartScreen and macOS Gatekeeper will warn on first launch (macOS: right-click → Open).

## Tests

```bash
flutter analyze
flutter test                                  # parsers (real yt-dlp output fixtures), queue, profiles/admin rules, playlists, service logic, cache
SMOKE=1 flutter test test/smoke_test.dart     # the same code against real YouTube (needs internet and the fetched binaries)
```

## Using it

1. First launch: choose an admin name and a PIN or password (4+ characters). There are no default credentials.
2. **Search** songs or playlists, tap a song to play (playback continues through the results). The "…" menu adds to queue / playlist.
3. **Settings → Manage profiles** (admin) to add people. Each profile signs in with its own PIN.
4. **Settings → Offline cache** to keep played songs on the device.
5. If YouTube says "Sign in to confirm you're not a bot": export your browser's YouTube cookies as a Netscape `cookies.txt` and choose it under **Settings → Cookies file**.

## Ideas borrowed from shinsoku

The yt-dlp behaviour (search filters, flat playlist expansion, link expiry and `available_at` handling, warming the next song, thumbnails straight from
`i.ytimg.com`, cookies, daily updates) was ported from shinsoku's `api/server.py` to Dart.

## Limits

- No iOS: iOS apps can't run yt-dlp.
- Live streams can't be played.
- The Android APK builds and its contents are verified, but it has not been run on a phone or emulator (no emulator was available in development). The desktop (Linux) build was run and tested end to end.
