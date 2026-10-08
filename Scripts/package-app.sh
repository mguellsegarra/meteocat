#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_app="${1:-$project_dir/Artifacts/Meteocat.app}"
fixture_test=false
if [[ "${2:-}" == "--fixture-test" ]]; then fixture_test=true; elif [[ $# -gt 1 ]]; then echo "Usage: $0 [destination.app] [--fixture-test]" >&2; exit 2; fi
if [[ "$output_app" != /* ]]; then output_app="$PWD/$output_app"; fi
if [[ "$output_app" != *.app || -e "$output_app" ]]; then echo "Destination must be a new .app path." >&2; exit 2; fi
build_scratch="$(mktemp -d /tmp/meteocat-package-sol.XXXXXX)"
build_hidden="${build_scratch}-hidden"
probe_scratch="$(mktemp -d /tmp/meteocat-package-probe-sol.XXXXXX)"
probe_hidden="${probe_scratch}-hidden"
relocation_root="$(mktemp -d /tmp/meteocat-relocation-sol.XXXXXX)"
cleanup() { rm -rf "$build_scratch" "$build_hidden" "$probe_scratch" "$probe_hidden" "$relocation_root"; }
trap cleanup EXIT
cd "$project_dir"
swift build -c release --scratch-path "$build_scratch" --product Meteocat
swift build -c release --scratch-path "$probe_scratch" --product FixtureImport
probe_bin_path="$(swift build -c release --scratch-path "$probe_scratch" --show-bin-path)"
bin_path="$(swift build -c release --scratch-path "$build_scratch" --show-bin-path)"
check_app="$relocation_root/Meteocat.app"
mkdir -p "$check_app/Contents/MacOS" "$check_app/Contents/Resources"
cp "$bin_path/Meteocat" "$check_app/Contents/MacOS/Meteocat"
cp "$probe_bin_path/FixtureImport" "$check_app/Contents/MacOS/FixtureImport"
cp "$project_dir/Scripts/Info.plist" "$check_app/Contents/Info.plist"
cp "$project_dir/Assets/Meteocat.icns" "$check_app/Contents/Resources/Meteocat.icns"
found_bundle=false
for resource_bundle in "$bin_path"/*.bundle; do
    [[ -d "$resource_bundle" ]] || continue
    cp -R "$resource_bundle" "$check_app/Contents/Resources/"
    found_bundle=true
done
[[ "$found_bundle" == true ]] || { echo "Missing SwiftPM resource bundle." >&2; exit 1; }
# Permission prompts are read by macOS from the main bundle, not the SwiftPM bundle.
for language in ca oc es eu gl en fr de it pt nl ro ar zgh ur zh-Hans uk ru pl pa bn; do
    localized_source="$project_dir/Sources/MeteocatApp/Resources/$language.lproj"
    # SwiftPM canonicalizes lproj directory names to lowercase.
    bundle_language="$(printf '%s' "$language" | tr '[:upper:]' '[:lower:]')"
    localized_bundle="$check_app/Contents/Resources/MeteocatNative_MeteocatApp.bundle/$bundle_language.lproj"
    if [[ ! -f "$localized_bundle/Localizable.strings" ]]; then
        localized_bundle="$check_app/Contents/Resources/MeteocatNative_MeteocatApp.bundle/Contents/Resources/$bundle_language.lproj"
    fi
    [[ -f "$localized_source/InfoPlist.strings" && -f "$localized_bundle/Localizable.strings" ]] || {
        echo "Missing localization resources: $language" >&2; exit 1;
    }
    mkdir -p "$check_app/Contents/Resources/$language.lproj"
    cp "$localized_source/InfoPlist.strings" "$check_app/Contents/Resources/$language.lproj/InfoPlist.strings"
    plutil -lint "$localized_bundle/Localizable.strings" "$check_app/Contents/Resources/$language.lproj/InfoPlist.strings"
done
python3 "$project_dir/Scripts/verify-localizations.py" --app "$check_app"
# Remove the entire build path from lookup before the local-only verifier runs.
mv "$build_scratch" "$build_hidden"
mv "$probe_scratch" "$probe_hidden"
"$check_app/Contents/MacOS/FixtureImport" --verify-resources
rm "$check_app/Contents/MacOS/FixtureImport"
plutil -lint "$check_app/Contents/Info.plist"
codesign --force --sign - "$check_app"
codesign --verify --deep --strict "$check_app"
mkdir -p "$(dirname "$output_app")"
mv "$check_app" "$output_app"
printf 'Packaged and verified: %s\n' "$output_app"
if [[ "$fixture_test" == true ]]; then
    printf 'Explicit offline test invocation (not launched): "%s/Contents/MacOS/Meteocat" --fixture\n' "$output_app"
fi
