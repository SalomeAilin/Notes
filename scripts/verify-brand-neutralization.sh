#!/bin/zsh

set -euo pipefail

notes_expected_display_name="InkNotes Dev"
notes_expected_bundle_identifier="com.salomeailin.InkNotes"
notes_expected_device_family="2"
notes_expected_deployment_target="17.0"
notes_repository_root="${0:A:h:h}"
notes_temp_base="${TMPDIR:-/tmp}"
notes_temp_base="${notes_temp_base%/}"
notes_temp_dir="$(mktemp -d "$notes_temp_base/inknotes-brand-gate.XXXXXX")"
chmod 700 "$notes_temp_dir"

cleanup() {
  if [[ -d "$notes_temp_dir" && "$notes_temp_dir" == "$notes_temp_base"/inknotes-brand-gate.* ]]; then
    rm -rf -- "$notes_temp_dir"
  fi
}
trap cleanup EXIT

cd "$notes_repository_root"

assert_equal() {
  local notes_actual="$1"
  local notes_expected="$2"
  local notes_label="$3"
  if [[ "$notes_actual" != "$notes_expected" ]]; then
    print -u2 "$notes_label mismatch"
    exit 1
  fi
}

assert_tree_has_no_retired_brand_marker() {
  local notes_tree_path="$1"
  local notes_label="$2"
  local notes_file
  local notes_relative_path
  while IFS= read -r -d '' notes_file; do
    if ! /usr/bin/perl -MEncode=encode -Mutf8 -0777 -e '
      my $data = <>;
      for my $marker ("墨记", "墨記", "墨计", "墨計") {
        for my $encoding ("UTF-8", "UTF-16LE", "UTF-16BE") {
          exit 1 if index($data, encode($encoding, $marker)) >= 0;
        }
      }
      exit 0;
    ' "$notes_file"
    then
      notes_relative_path="${notes_file#$notes_tree_path/}"
      print -u2 "$notes_label contains a retired display name in: $notes_relative_path"
      exit 1
    fi
  done < <(find "$notes_tree_path" -type f -print0)
}

assert_retired_brand_scanner_negative_controls() {
  local notes_encoding
  local notes_fixture_dir
  local notes_marker
  local notes_marker_index=0
  for notes_marker in "墨记" "墨記" "墨计" "墨計"; do
    notes_marker_index=$((notes_marker_index + 1))
    for notes_encoding in UTF-8 UTF-16LE UTF-16BE; do
      notes_fixture_dir="$notes_temp_dir/negative-$notes_marker_index-$notes_encoding"
      mkdir -p "$notes_fixture_dir"
      /usr/bin/perl -MEncode=decode,encode -Mutf8 -e '
        my ($encoding, $marker_bytes) = @ARGV;
        my $marker = decode("UTF-8", $marker_bytes);
        print encode($encoding, $marker);
      ' "$notes_encoding" "$notes_marker" > "$notes_fixture_dir/display-name.bin"

      if (assert_tree_has_no_retired_brand_marker "$notes_fixture_dir" "Negative control") \
        >/dev/null 2>&1
      then
        print -u2 "Retired-brand scanner failed negative control $notes_marker_index/$notes_encoding"
        exit 1
      fi
    done
  done
}

print "[1/4] Checking source format and brand identity tests"
xcrun swift-format lint --strict --recursive InkNotes InkNotesCoreTests Package.swift
xcrun swift test

print "[2/4] Checking source display name and retired-name scanner"
notes_source_display_name="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' InkNotes/Info.plist
)"
assert_equal "$notes_source_display_name" "$notes_expected_display_name" "Source display name"
assert_retired_brand_scanner_negative_controls
assert_tree_has_no_retired_brand_marker "InkNotes" "Shipping source"

print "[3/4] Building Debug and Release generic iOS products"
for notes_configuration in Debug Release; do
  notes_settings_json="$notes_temp_dir/$notes_configuration-build-settings.json"
  xcodebuild \
    -project InkNotes.xcodeproj \
    -scheme InkNotes \
    -configuration "$notes_configuration" \
    -destination 'generic/platform=iOS' \
    -showBuildSettings \
    -json > "$notes_settings_json"

  notes_bundle_identifier="$(
    plutil -extract 0.buildSettings.PRODUCT_BUNDLE_IDENTIFIER raw -o - "$notes_settings_json"
  )"
  notes_device_family="$(
    plutil -extract 0.buildSettings.TARGETED_DEVICE_FAMILY raw -o - "$notes_settings_json"
  )"
  notes_deployment_target="$(
    plutil -extract 0.buildSettings.IPHONEOS_DEPLOYMENT_TARGET raw -o - "$notes_settings_json"
  )"
  assert_equal \
    "$notes_bundle_identifier" \
    "$notes_expected_bundle_identifier" \
    "$notes_configuration bundle identifier"
  assert_equal \
    "$notes_device_family" \
    "$notes_expected_device_family" \
    "$notes_configuration device family"
  assert_equal \
    "$notes_deployment_target" \
    "$notes_expected_deployment_target" \
    "$notes_configuration deployment target"

  notes_derived_data="$notes_temp_dir/DerivedData-$notes_configuration"
  xcodebuild -quiet \
    -project InkNotes.xcodeproj \
    -scheme InkNotes \
    -configuration "$notes_configuration" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$notes_derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    build

  notes_app_path="$notes_derived_data/Build/Products/$notes_configuration-iphoneos/InkNotes.app"
  notes_built_plist="$notes_app_path/Info.plist"
  [[ -f "$notes_built_plist" ]] || {
    print -u2 "$notes_configuration app Info.plist is missing"
    exit 1
  }
  notes_built_display_name="$(
    plutil -extract CFBundleDisplayName raw -o - "$notes_built_plist"
  )"
  notes_built_bundle_identifier="$(
    plutil -extract CFBundleIdentifier raw -o - "$notes_built_plist"
  )"
  assert_equal \
    "$notes_built_display_name" \
    "$notes_expected_display_name" \
    "$notes_configuration built display name"
  assert_equal \
    "$notes_built_bundle_identifier" \
    "$notes_expected_bundle_identifier" \
    "$notes_configuration built bundle identifier"
  assert_tree_has_no_retired_brand_marker "$notes_app_path" "$notes_configuration built app"
done

print "[4/4] Internal display name, stable app identity, and retired-name gate passed"
