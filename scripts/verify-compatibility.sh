#!/bin/zsh
set -euo pipefail

notes_repository_root="${0:A:h:h}"
notes_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
notes_expected_bundle_id="com.salomeailin.InkNotes"
notes_expected_uti="com.salomeailin.notes.backup"
notes_expected_extension="notesbackup"
notes_expected_mime="application/vnd.salomeailin.notes-backup"

if [[ ! -d "$notes_developer_dir" ]]; then
  print -u2 "Xcode developer directory not found: $notes_developer_dir"
  exit 1
fi

export DEVELOPER_DIR="$notes_developer_dir"
cd "$notes_repository_root"

notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-compatibility.XXXXXX")"
chmod 700 "$notes_temp_dir"
trap 'rm -rf "$notes_temp_dir"' EXIT

assert_equal() {
  local notes_actual="$1"
  local notes_expected="$2"
  local notes_label="$3"
  if [[ "$notes_actual" != "$notes_expected" ]]; then
    print -u2 "$notes_label mismatch: expected '$notes_expected', got '$notes_actual'"
    exit 1
  fi
}

print "[1/4] Running Swift compatibility tests"
xcrun swift test

notes_source_plist="InkNotes/Info.plist"
notes_source_uti="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$notes_source_plist")"
notes_source_extension="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0' "$notes_source_plist")"
notes_source_mime="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.mime-type' "$notes_source_plist")"
assert_equal "$notes_source_uti" "$notes_expected_uti" "Source UTI"
assert_equal "$notes_source_extension" "$notes_expected_extension" "Source filename extension"
assert_equal "$notes_source_mime" "$notes_expected_mime" "Source MIME type"
print "[2/4] Source backup identity is stable"

for notes_configuration in Debug Release; do
  notes_settings_json="$notes_temp_dir/$notes_configuration-settings.json"
  notes_settings_log="$notes_temp_dir/$notes_configuration-settings.log"
  if ! xcodebuild \
    -project InkNotes.xcodeproj \
    -scheme InkNotes \
    -configuration "$notes_configuration" \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -showBuildSettings \
    -json > "$notes_settings_json" 2> "$notes_settings_log"
  then
    print -u2 "$notes_configuration build-settings check failed; raw diagnostics were withheld and deleted."
    exit 1
  fi

  notes_bundle_id="$(plutil -extract 0.buildSettings.PRODUCT_BUNDLE_IDENTIFIER raw -o - "$notes_settings_json")"
  assert_equal "$notes_bundle_id" "$notes_expected_bundle_id" "$notes_configuration bundle identifier"
done
print "[3/4] Debug and Release bundle identifiers are stable"

for notes_configuration in Debug Release; do
  notes_derived_data="$notes_temp_dir/DerivedData-$notes_configuration"
  notes_build_log="$notes_temp_dir/$notes_configuration-build.log"
  if ! xcodebuild \
    -project InkNotes.xcodeproj \
    -scheme InkNotes \
    -configuration "$notes_configuration" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$notes_derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build > "$notes_build_log" 2>&1
  then
    print -u2 "$notes_configuration iOS build failed; raw diagnostics were withheld and deleted."
    exit 1
  fi

  notes_settings_json="$notes_temp_dir/$notes_configuration-settings.json"
  notes_full_product_name="$(plutil -extract 0.buildSettings.FULL_PRODUCT_NAME raw -o - "$notes_settings_json")"
  notes_built_plist="$notes_derived_data/Build/Products/$notes_configuration-iphoneos/$notes_full_product_name/Info.plist"
  if [[ ! -f "$notes_built_plist" ]]; then
    print -u2 "$notes_configuration built Info.plist was not found"
    exit 1
  fi

  notes_built_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$notes_built_plist")"
  notes_minimum_os="$(plutil -extract MinimumOSVersion raw -o - "$notes_built_plist")"
  notes_device_family="$(plutil -extract UIDeviceFamily json -o - "$notes_built_plist")"
  notes_built_uti="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$notes_built_plist")"
  notes_built_extension="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0' "$notes_built_plist")"
  notes_built_mime="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.mime-type' "$notes_built_plist")"

  assert_equal "$notes_built_bundle_id" "$notes_expected_bundle_id" "$notes_configuration built bundle identifier"
  assert_equal "$notes_minimum_os" "17.0" "$notes_configuration minimum iOS version"
  assert_equal "$notes_device_family" '[2]' "$notes_configuration device family"
  assert_equal "$notes_built_uti" "$notes_expected_uti" "$notes_configuration built UTI"
  assert_equal "$notes_built_extension" "$notes_expected_extension" "$notes_configuration built filename extension"
  assert_equal "$notes_built_mime" "$notes_expected_mime" "$notes_configuration built MIME type"
done

print "[4/4] Debug and Release products preserve iPadOS 17+ and backup identities"
print "Compatibility gate passed"
