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

notes_display_name_contract="$notes_repository_root/scripts/internal-display-name-contract.zsh"
if [[ ! -f "$notes_display_name_contract" || -L "$notes_display_name_contract" ]]; then
  print -u2 "Internal display-name contract is missing or unsafe"
  exit 1
fi
source "$notes_display_name_contract"

assert_equal() {
  local notes_actual="$1"
  local notes_expected="$2"
  local notes_label="$3"
  if [[ "$notes_actual" != "$notes_expected" ]]; then
    print -u2 "$notes_label mismatch: expected '$notes_expected', got '$notes_actual'"
    exit 1
  fi
}

assert_internal_display_name_contract_rejects_invalid_values() {
  local notes_fixture_plist
  local notes_fixture_value
  local notes_fixture_raw_path
  local notes_invalid_name
  local notes_invalid_index=0
  local -a notes_invalid_names=(
    ""
    "   "
    " Valid Name"
    "Valid Name "
    $'\u3000Valid Name'
    $'Valid Name\u3000'
    $'Valid\nName'
    $'Valid Name\n'
    $'Valid\tName'
    $'Valid\u200BName'
    $'Valid\u202EName'
    $'Valid\u2066Name'
    '$('
    '${'
    '$(PRODUCT_NAME)'
    '${PRODUCT_NAME}'
    "prefix墨记suffix"
    "prefix墨記suffix"
    "prefix墨计suffix"
    "prefix墨計suffix"
  )

  notes_fixture_plist="$notes_temp_dir/display-name-positive-control.plist"
  plutil -create xml1 "$notes_fixture_plist"
  plutil -insert CFBundleDisplayName -string "Valid Name" "$notes_fixture_plist"
  notes_read_internal_display_name \
    "$notes_fixture_plist" \
    CFBundleDisplayName \
    "$notes_temp_dir" \
    notes_fixture_value \
    notes_fixture_raw_path \
    "Positive control" >/dev/null

  notes_fixture_plist="$notes_temp_dir/display-name-missing-key.plist"
  plutil -create xml1 "$notes_fixture_plist"
  if (notes_read_internal_display_name \
    "$notes_fixture_plist" \
    CFBundleDisplayName \
    "$notes_temp_dir" \
    notes_fixture_value \
    notes_fixture_raw_path \
    "Negative control") >/dev/null 2>&1
  then
    print -u2 "Internal display-name contract accepted a missing key"
    exit 1
  fi

  notes_fixture_plist="$notes_temp_dir/display-name-non-string.plist"
  plutil -create xml1 "$notes_fixture_plist"
  plutil -insert CFBundleDisplayName -bool true "$notes_fixture_plist"
  if (notes_read_internal_display_name \
    "$notes_fixture_plist" \
    CFBundleDisplayName \
    "$notes_temp_dir" \
    notes_fixture_value \
    notes_fixture_raw_path \
    "Negative control") >/dev/null 2>&1
  then
    print -u2 "Internal display-name contract accepted a non-string value"
    exit 1
  fi

  for notes_invalid_name in "${notes_invalid_names[@]}"; do
    (( notes_invalid_index += 1 ))
    notes_fixture_plist="$notes_temp_dir/display-name-negative-control-$notes_invalid_index.plist"
    plutil -create xml1 "$notes_fixture_plist"
    plutil -insert CFBundleDisplayName -string "$notes_invalid_name" "$notes_fixture_plist"
    if (notes_read_internal_display_name \
      "$notes_fixture_plist" \
      CFBundleDisplayName \
      "$notes_temp_dir" \
      notes_fixture_value \
      notes_fixture_raw_path \
      "Negative control") >/dev/null 2>&1
    then
      print -u2 "Internal display-name contract failed negative control $notes_invalid_index"
      exit 1
    fi
  done
}

assert_internal_display_name_reader_rejects_localized_overrides() {
  local notes_fixture_tree="$notes_temp_dir/display-name-localization-negative-control"

  mkdir -p "$notes_fixture_tree/en.lproj"
  plutil -create binary1 "$notes_fixture_tree/en.lproj/InfoPlist.strings"
  plutil -insert CFBundleDisplayName -string "Localized Override" \
    "$notes_fixture_tree/en.lproj/InfoPlist.strings"
  if (notes_assert_no_localized_display_name_override \
    "$notes_fixture_tree" \
    "$notes_temp_dir" \
    "Negative control") >/dev/null 2>&1
  then
    print -u2 "Localized display-name override escaped the contract"
    exit 1
  fi

  plutil -replace CFBundleDisplayName -bool true \
    "$notes_fixture_tree/en.lproj/InfoPlist.strings"
  if (notes_assert_no_localized_display_name_override \
    "$notes_fixture_tree" \
    "$notes_temp_dir" \
    "Negative control") >/dev/null 2>&1
  then
    print -u2 "Non-string localized display-name key escaped the contract"
    exit 1
  fi

  plutil -remove CFBundleDisplayName "$notes_fixture_tree/en.lproj/InfoPlist.strings"
  plutil -insert CFBundleDisplayName -array \
    "$notes_fixture_tree/en.lproj/InfoPlist.strings"
  if (notes_assert_no_localized_display_name_override \
    "$notes_fixture_tree" \
    "$notes_temp_dir" \
    "Negative control") >/dev/null 2>&1
  then
    print -u2 "Array localized display-name key escaped the contract"
    exit 1
  fi
}

assert_plist_key_absent() {
  local notes_plist_path="$1"
  local notes_key="$2"
  local notes_label="$3"
  if /usr/libexec/PlistBuddy -c "Print :$notes_key" "$notes_plist_path" >/dev/null 2>&1; then
    print -u2 "$notes_label must remain absent"
    exit 1
  fi
}

assert_ipad_presentation_contract() {
  local notes_plist_path="$1"
  local notes_label="$2"
  local notes_multiple_scenes
  local notes_indirect_input
  local notes_orientation_count
  local notes_orientation_index
  local notes_actual_orientation
  local -a notes_expected_orientations=(
    UIInterfaceOrientationPortrait
    UIInterfaceOrientationPortraitUpsideDown
    UIInterfaceOrientationLandscapeLeft
    UIInterfaceOrientationLandscapeRight
  )

  notes_multiple_scenes="$(
    plutil -extract UIApplicationSceneManifest.UIApplicationSupportsMultipleScenes raw \
      -expect bool -o - "$notes_plist_path"
  )"
  notes_indirect_input="$(
    plutil -extract UIApplicationSupportsIndirectInputEvents raw -expect bool -o - \
      "$notes_plist_path"
  )"
  notes_orientation_count="$(
    plutil -extract 'UISupportedInterfaceOrientations~ipad' raw -expect array -o - \
      "$notes_plist_path"
  )"

  assert_equal "$notes_multiple_scenes" "false" "$notes_label multiple-scene capability"
  assert_equal "$notes_indirect_input" "true" "$notes_label indirect-input capability"
  assert_equal "$notes_orientation_count" "4" "$notes_label iPad orientation count"
  for notes_orientation_index in {1..4}; do
    notes_actual_orientation="$(
      plutil -extract \
        "UISupportedInterfaceOrientations~ipad.$((notes_orientation_index - 1))" \
        raw -expect string -o - "$notes_plist_path"
    )"
    assert_equal \
      "$notes_actual_orientation" \
      "$notes_expected_orientations[$notes_orientation_index]" \
      "$notes_label iPad orientation $notes_orientation_index"
  done
  assert_plist_key_absent "$notes_plist_path" "UIRequiresFullScreen" "$notes_label full-screen requirement"
}

assert_ipad_presentation_contract_rejects_invalid_fixtures() {
  local notes_source_plist="$1"
  local notes_fixture_dir="$notes_temp_dir/ipad-presentation-negative-controls"
  local notes_fixture
  local notes_scenario
  mkdir -p "$notes_fixture_dir"

  for notes_scenario in multiple-scenes-type full-screen orientations indirect-input; do
    notes_fixture="$notes_fixture_dir/$notes_scenario.plist"
    cp "$notes_source_plist" "$notes_fixture"
    case "$notes_scenario" in
      multiple-scenes-type)
        /usr/libexec/PlistBuddy \
          -c 'Delete :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes' \
          "$notes_fixture" >/dev/null
        /usr/libexec/PlistBuddy \
          -c 'Add :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes integer 0' \
          "$notes_fixture" >/dev/null
        ;;
      full-screen)
        /usr/libexec/PlistBuddy -c 'Add :UIRequiresFullScreen bool false' \
          "$notes_fixture" >/dev/null
        ;;
      orientations)
        /usr/libexec/PlistBuddy \
          -c 'Set :UISupportedInterfaceOrientations~ipad:0 UIInterfaceOrientationLandscapeLeft' \
          "$notes_fixture" >/dev/null
        /usr/libexec/PlistBuddy \
          -c 'Set :UISupportedInterfaceOrientations~ipad:2 UIInterfaceOrientationPortrait' \
          "$notes_fixture" >/dev/null
        ;;
      indirect-input)
        /usr/libexec/PlistBuddy \
          -c 'Set :UIApplicationSupportsIndirectInputEvents false' \
          "$notes_fixture" >/dev/null
        ;;
    esac

    if (assert_ipad_presentation_contract "$notes_fixture" "Negative control") \
      >/dev/null 2>&1
    then
      print -u2 "iPad presentation contract failed its $notes_scenario negative control"
      exit 1
    fi
  done
}

assert_build_setting_absent() {
  local notes_settings_path="$1"
  local notes_key="$2"
  local notes_label="$3"
  if plutil -extract "0.buildSettings.$notes_key" raw -o - "$notes_settings_path" >/dev/null 2>&1; then
    print -u2 "$notes_label contains forbidden build setting '$notes_key'"
    exit 1
  fi
}

assert_app_has_no_oauth_release_markers() {
  local notes_app_path="$1"
  local notes_file
  local notes_relative_path
  while IFS= read -r -d '' notes_file; do
    if ! /usr/bin/perl -MEncode=encode -Mutf8 -0777 -e '
      my $data = <>;
      my @markers = (
        "client_secret", "clientSecret", "CLIENT_SECRET",
        "SecretKey", "secret_key", "SECRET_KEY",
        "openapi.baidu.com", "passport.baidu.com", "/oauth/2.0/",
        "OAuthBrokerURL", "OAuthCallback", "BaiduClientID", "BaiduAppKey",
        "AuthenticationServices", "ASWebAuthenticationSession",
        "com.apple.developer.associated-domains", "applinks:",
        "BGTaskScheduler", "BGProcessingTask", "BGAppRefreshTask",
        "BGTaskSchedulerPermittedIdentifiers", "backgroundWithIdentifier",
        "example.com", "example.net", "example.org", "example.invalid",
        "://localhost", "://127.0.0.1", "://[::1]", "已连接"
      );
      for my $marker (@markers) {
        for my $encoding ("UTF-8", "UTF-16LE", "UTF-16BE") {
          exit 1 if index($data, encode($encoding, $marker)) >= 0;
        }
      }
      exit 0;
    ' "$notes_file"
    then
      notes_relative_path="${notes_file#$notes_app_path/}"
      print -u2 "Built app contains a forbidden OAuth release marker in: $notes_relative_path"
      exit 1
    fi
  done < <(find "$notes_app_path" -type f -print0)
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
      print -u2 "$notes_label contains the retired display name in: $notes_relative_path"
      exit 1
    fi
  done < <(find "$notes_tree_path" -type f -print0)
}

assert_retired_brand_scanner_detects_chinese_encodings() {
  local notes_encoding
  local notes_fixture_dir
  local notes_marker
  local notes_variant_index=0
  for notes_marker in "墨记" "墨記" "墨计" "墨計"; do
    (( notes_variant_index += 1 ))
    for notes_encoding in UTF-8 UTF-16LE UTF-16BE; do
      notes_fixture_dir="$notes_temp_dir/brand-scanner-negative-control-$notes_variant_index-$notes_encoding"
      mkdir -p "$notes_fixture_dir"
      /usr/bin/perl -MEncode=decode,encode -e '
        my ($encoding, $marker) = @ARGV;
        $marker = decode("UTF-8", $marker);
        print encode($encoding, $marker);
      ' "$notes_encoding" "$notes_marker" > "$notes_fixture_dir/display-name.bin"

      if (assert_tree_has_no_retired_brand_marker "$notes_fixture_dir" "Negative control") >/dev/null 2>&1; then
        print -u2 "Retired-brand scanner failed alias $notes_variant_index $notes_encoding negative control"
        exit 1
      fi
    done
  done
}

assert_oauth_release_marker_scanner_detects_chinese_encodings() {
  local notes_encoding
  local notes_fixture_dir
  for notes_encoding in UTF-8 UTF-16LE UTF-16BE; do
    notes_fixture_dir="$notes_temp_dir/oauth-scanner-negative-control-$notes_encoding"
    mkdir -p "$notes_fixture_dir"
    /usr/bin/perl -MEncode=encode -Mutf8 -e '
      my $encoding = shift;
      print encode($encoding, "已连接");
    ' "$notes_encoding" > "$notes_fixture_dir/connection-state.bin"

    if (assert_app_has_no_oauth_release_markers "$notes_fixture_dir") >/dev/null 2>&1; then
      print -u2 "Built-app OAuth scanner failed its $notes_encoding Chinese negative control"
      exit 1
    fi
  done
}

print "[1/5] Checking Swift format"
xcrun swift-format lint --strict --recursive InkNotes InkNotesCoreTests Package.swift
zsh -n scripts/build-signed-ipad-app.sh
zsh -n scripts/verify-ipad-readiness.sh
zsh -n scripts/internal-display-name-contract.zsh
scripts/build-signed-ipad-app.sh --help >/dev/null
scripts/verify-ipad-readiness.sh --help >/dev/null

print "[2/5] Running Swift compatibility tests"
xcrun swift test
assert_oauth_release_marker_scanner_detects_chinese_encodings
assert_retired_brand_scanner_detects_chinese_encodings
assert_tree_has_no_retired_brand_marker "InkNotes" "Shipping source"
assert_internal_display_name_contract_rejects_invalid_values
assert_internal_display_name_reader_rejects_localized_overrides

notes_source_plist="InkNotes/Info.plist"
notes_read_internal_display_name \
  "$notes_source_plist" \
  CFBundleDisplayName \
  "$notes_temp_dir" \
  notes_source_display_name \
  notes_source_display_name_raw \
  "Source internal display name"
notes_source_uti="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$notes_source_plist")"
notes_source_extension="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0' "$notes_source_plist")"
notes_source_mime="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.mime-type' "$notes_source_plist")"
notes_source_document_uti="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSItemContentTypes:0' "$notes_source_plist")"
notes_source_document_role="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:CFBundleTypeRole' "$notes_source_plist")"
notes_source_handler_rank="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSHandlerRank' "$notes_source_plist")"
notes_source_open_in_place="$(plutil -extract LSSupportsOpeningDocumentsInPlace raw -o - "$notes_source_plist")"
assert_equal "$notes_source_uti" "$notes_expected_uti" "Source UTI"
assert_equal "$notes_source_extension" "$notes_expected_extension" "Source filename extension"
assert_equal "$notes_source_mime" "$notes_expected_mime" "Source MIME type"
assert_equal "$notes_source_document_uti" "$notes_expected_uti" "Source document UTI"
assert_equal "$notes_source_document_role" "Viewer" "Source document role"
assert_equal "$notes_source_handler_rank" "Alternate" "Source document handler rank"
assert_equal "$notes_source_open_in_place" "false" "Source open-in-place capability"
assert_ipad_presentation_contract "$notes_source_plist" "Source"
assert_ipad_presentation_contract_rejects_invalid_fixtures "$notes_source_plist"
assert_plist_key_absent "$notes_source_plist" "CFBundleURLTypes" "Source callback registration"
assert_plist_key_absent "$notes_source_plist" "CFBundleURLSchemes" "Source callback scheme"
assert_plist_key_absent "$notes_source_plist" "UIBackgroundModes" "Source background transfer capability"
assert_plist_key_absent "$notes_source_plist" "BGTaskSchedulerPermittedIdentifiers" "Source background task registration"
print "[3/5] Source backup identity and unconfigured OAuth boundary are stable"

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
  notes_info_plist_file="$(plutil -extract 0.buildSettings.INFOPLIST_FILE raw -o - "$notes_settings_json")"
  notes_generates_info_plist="$(plutil -extract 0.buildSettings.GENERATE_INFOPLIST_FILE raw -o - "$notes_settings_json")"
  notes_preprocesses_info_plist="$(plutil -extract 0.buildSettings.INFOPLIST_PREPROCESS raw -o - "$notes_settings_json")"
  assert_equal "$notes_bundle_id" "$notes_expected_bundle_id" "$notes_configuration bundle identifier"
  assert_equal "$notes_info_plist_file" "InkNotes/Info.plist" "$notes_configuration source Info.plist"
  assert_equal "$notes_generates_info_plist" "NO" "$notes_configuration generated Info.plist setting"
  assert_equal "$notes_preprocesses_info_plist" "NO" "$notes_configuration Info.plist preprocessing"
  for notes_forbidden_setting in \
    BAIDU_CLIENT_SECRET BAIDU_SECRET_KEY BAIDU_APP_SECRET CLIENT_SECRET SECRET_KEY \
    BAIDU_OAUTH_BROKER_URL BAIDU_OAUTH_CALLBACK BAIDU_CLIENT_ID BAIDU_APP_KEY \
    CODE_SIGN_ENTITLEMENTS INFOPLIST_KEY_CFBundleDisplayName \
    INFOPLIST_KEY_CFBundleURLTypes INFOPLIST_KEY_CFBundleURLSchemes \
    INFOPLIST_KEY_UIBackgroundModes INFOPLIST_KEY_BGTaskSchedulerPermittedIdentifiers
  do
    assert_build_setting_absent \
      "$notes_settings_json" \
      "$notes_forbidden_setting" \
      "$notes_configuration"
  done
done
print "[4/5] Debug and Release bundle identifiers and OAuth settings are stable"

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
  notes_read_internal_display_name \
    "$notes_built_plist" \
    CFBundleDisplayName \
    "$notes_temp_dir" \
    notes_built_display_name \
    notes_built_display_name_raw \
    "$notes_configuration built internal display name"
  notes_minimum_os="$(plutil -extract MinimumOSVersion raw -o - "$notes_built_plist")"
  notes_device_family="$(plutil -extract UIDeviceFamily json -o - "$notes_built_plist")"
  notes_built_uti="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$notes_built_plist")"
  notes_built_extension="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0' "$notes_built_plist")"
  notes_built_mime="$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.mime-type' "$notes_built_plist")"
  notes_built_document_uti="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSItemContentTypes:0' "$notes_built_plist")"
  notes_built_document_role="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:CFBundleTypeRole' "$notes_built_plist")"
  notes_built_handler_rank="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSHandlerRank' "$notes_built_plist")"
  notes_built_open_in_place="$(plutil -extract LSSupportsOpeningDocumentsInPlace raw -o - "$notes_built_plist")"

  assert_equal "$notes_built_bundle_id" "$notes_expected_bundle_id" "$notes_configuration built bundle identifier"
  cmp -s "$notes_built_display_name_raw" "$notes_source_display_name_raw" \
    || {
      print -u2 "$notes_configuration built internal display name drifted from source"
      exit 1
    }
  assert_equal "$notes_minimum_os" "17.0" "$notes_configuration minimum iOS version"
  assert_equal "$notes_device_family" '[2]' "$notes_configuration device family"
  assert_equal "$notes_built_uti" "$notes_expected_uti" "$notes_configuration built UTI"
  assert_equal "$notes_built_extension" "$notes_expected_extension" "$notes_configuration built filename extension"
  assert_equal "$notes_built_mime" "$notes_expected_mime" "$notes_configuration built MIME type"
  assert_equal "$notes_built_document_uti" "$notes_expected_uti" "$notes_configuration built document UTI"
  assert_equal "$notes_built_document_role" "Viewer" "$notes_configuration built document role"
  assert_equal "$notes_built_handler_rank" "Alternate" "$notes_configuration built document handler rank"
  assert_equal "$notes_built_open_in_place" "false" "$notes_configuration open-in-place capability"
  assert_ipad_presentation_contract "$notes_built_plist" "$notes_configuration built"
  assert_plist_key_absent "$notes_built_plist" "CFBundleURLTypes" "$notes_configuration callback registration"
  assert_plist_key_absent "$notes_built_plist" "CFBundleURLSchemes" "$notes_configuration callback scheme"
  assert_plist_key_absent "$notes_built_plist" "UIBackgroundModes" "$notes_configuration background transfer capability"
  assert_plist_key_absent "$notes_built_plist" "BGTaskSchedulerPermittedIdentifiers" "$notes_configuration background task registration"
  notes_assert_no_localized_display_name_override \
    "${notes_built_plist:h}" \
    "$notes_temp_dir" \
    "$notes_configuration built app"
  assert_app_has_no_oauth_release_markers "${notes_built_plist:h}"
  assert_tree_has_no_retired_brand_marker "${notes_built_plist:h}" "$notes_configuration built app"
done

print "[5/5] Debug and Release products preserve iPad presentation, app identity, backup, and fail-closed OAuth contracts"
print "Compatibility gate passed"
