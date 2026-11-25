#!/usr/bin/env bash
# For the release workflow: prints VERSION_ARGS=... (extra arguments for `flutter build`) taken from a vX.Y.Z tag.
# Builds that are not from a tag get an empty value: they keep the pubspec version and never look for updates.
set -euo pipefail
if [ "${GITHUB_REF_TYPE:-}" != tag ]; then
  echo "VERSION_ARGS="
  exit 0
fi
if ! [[ "${GITHUB_REF_NAME:-}" =~ ^v([0-9]{1,4})\.([0-9]{1,2})\.([0-9]{1,2})$ ]]; then
  echo "::error::Release tags must look like v1.2.3 (minor and patch up to 99), got '${GITHUB_REF_NAME:-}'" >&2
  exit 1
fi
version=${GITHUB_REF_NAME#v}
# Android needs a number that grows with every release.
code=$((10#${BASH_REMATCH[1]} * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]}))
echo "VERSION_ARGS=--build-name=$version --build-number=$code --dart-define=APP_VERSION=$version"
