#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# ARCHS=universal builds for Apple Silicon and Intel; default is the current Mac.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
./scripts/build-icon.sh
app="$PWD/dist/USBKey.app"
mkdir -p "$PWD/dist"
architectures=("$(uname -m)")
if [[ "${ARCHS:-native}" == universal ]]; then architectures=(arm64 x86_64); fi
binaries=()
lifecycle_binaries=()
for architecture in "${architectures[@]}"; do
    args=(--disable-sandbox --build-system native --triple "${architecture}-apple-macosx13.0" --scratch-path ".build/$architecture")
    swift build -c release "${args[@]}"
    bin_dir=$(swift build -c release "${args[@]}" --show-bin-path)
    binaries+=("$bin_dir/USBKey")
    lifecycle_binaries+=("$bin_dir/USBKeyLifecycle")
done
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
if [[ ${#binaries[@]} -gt 1 ]]; then
    /usr/bin/lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/USBKey"
else
    cp "${binaries[0]}" "$app/Contents/MacOS/USBKey"
fi
if [[ ${#lifecycle_binaries[@]} -gt 1 ]]; then
    /usr/bin/lipo -create "${lifecycle_binaries[@]}" -output "$app/Contents/Helpers/USBKeyLifecycle"
else
    cp "${lifecycle_binaries[0]}" "$app/Contents/Helpers/USBKeyLifecycle"
fi
python3 scripts/sign-app.py "$app/Contents/Helpers/USBKeyLifecycle" local.usbkey.lifecycle
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/usbkey-sign "$app/Contents/Resources/usbkey-sign"
chmod 755 "$app/Contents/Resources/usbkey-sign"
# Use a stable Developer ID identity for distribution and Keychain continuity.
python3 scripts/sign-app.py "$app"
stage="$PWD/.build/pkgroot"
rm -rf "$stage"
mkdir -p "$stage/Applications" "$stage/Library/LaunchAgents"
/usr/bin/ditto --noextattr "$app" "$stage/Applications/USBKey.app"
cp Resources/local.usbkey.autostart.plist "$stage/Library/LaunchAgents/"
chmod 644 "$stage/Library/LaunchAgents/local.usbkey.autostart.plist"
installer_scripts="$PWD/.build/installer-scripts"
mkdir -p "$installer_scripts"
cp scripts/installer/preinstall scripts/installer/postinstall "$installer_scripts/"
cp "$app/Contents/Helpers/USBKeyLifecycle" "$installer_scripts/close-usbkey"
chmod 755 "$installer_scripts/preinstall" "$installer_scripts/postinstall" "$installer_scripts/close-usbkey"
pkg_args=(--root "$stage" --component-plist Resources/component.plist --install-location / --scripts "$installer_scripts" --identifier local.usbkey.pkg --version 0.3.5)
if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then pkg_args+=(--sign "$INSTALLER_SIGN_IDENTITY"); fi
pkgbuild "${pkg_args[@]}" "$PWD/dist/USBKey-0.3.5.pkg"
echo "Ready: $PWD/dist/USBKey-0.3.5.pkg"
