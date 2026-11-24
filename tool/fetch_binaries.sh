#!/usr/bin/env bash
# Fetches the helper binaries the app bundles. Run once before `flutter build`.
#
#  - desktop: yt-dlp + quickjs-ng (`qjs`, the JS runtime yt-dlp uses to solve YouTube's challenges) under assets/bin/<os>/
#    (deno was tried and rejected: deno 2.9.8 produced challenge answers YouTube answered with HTTP 403)
#  - android: quickjs-ng as libqjs.so under android/app/src/main/jniLibs/<abi>/ (only files in the app's
#    native-library folder may be executed on modern Android; yt-dlp itself comes from youtubedl-android).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/assets/bin"
jni="$root/android/app/src/main/jniLibs"
mkdir -p "$out/linux" "$out/windows" "$out/macos" "$jni/arm64-v8a" "$jni/armeabi-v7a" "$jni/x86_64"

ytdlp="https://github.com/yt-dlp/yt-dlp/releases/latest/download"
curl -fsSL -o "$out/linux/yt-dlp"       "$ytdlp/yt-dlp_linux"
curl -fsSL -o "$out/windows/yt-dlp.exe" "$ytdlp/yt-dlp.exe"
curl -fsSL -o "$out/macos/yt-dlp"       "$ytdlp/yt-dlp_macos"

qjs="https://github.com/quickjs-ng/quickjs/releases/download/v0.18.0"
curl -fsSL -o "$out/linux/qjs"        "$qjs/qjs-linux-x86_64"
curl -fsSL -o "$out/windows/qjs.exe"  "$qjs/qjs-windows-x86_64.exe"
curl -fsSL -o "$out/macos/qjs"        "$qjs/qjs-darwin-arm64"
curl -fsSL -o "$jni/arm64-v8a/libqjs.so"   "$qjs/qjs-linux-aarch64"
curl -fsSL -o "$jni/armeabi-v7a/libqjs.so" "$qjs/qjs-linux-armv7"
curl -fsSL -o "$jni/x86_64/libqjs.so"      "$qjs/qjs-linux-x86_64"

chmod +x "$out/linux/"* "$out/macos/"* "$jni"/*/libqjs.so
echo "done"
