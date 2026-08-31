notes_validate_internal_display_name_file() {
  local notes_raw_path="$1"
  local notes_label="${2:-Internal display name}"

  if ! /usr/bin/perl -MEncode=decode -Mutf8 -0777 -e '
    use strict;
    use warnings;

    my $bytes = <>;
    my $value;
    eval {
      $value = decode("UTF-8", $bytes, Encode::FB_CROAK());
      1;
    } or exit 1;
    exit 1 if length($value) == 0;
    exit 1 if $value =~ /\A\p{White_Space}*\z/u;
    exit 1 if $value =~ /\A\p{White_Space}|\p{White_Space}\z/u;
    exit 1 if $value =~ /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u;
    exit 1 if index($value, "\$(") >= 0 || index($value, "\${") >= 0;
    for my $retired_name ("墨记", "墨記", "墨计", "墨計") {
      exit 1 if index($value, $retired_name) >= 0;
    }
  ' "$notes_raw_path"
  then
    print -u2 -- "$notes_label violates the internal display-name contract"
    return 1
  fi
}

notes_read_validated_display_name() {
  local notes_plist_path="$1"
  local notes_plist_key="$2"
  local notes_temporary_directory="$3"
  local notes_result_variable="$4"
  local notes_raw_path_variable="$5"
  local notes_label="${6:-Internal display name}"
  local notes_extraction_directory
  local notes_raw_path
  local notes_value=""

  if [[ ! -f "$notes_plist_path" || -L "$notes_plist_path" ]]; then
    print -u2 -- "$notes_label source plist is missing or unsafe"
    return 1
  fi
  if [[ ! -d "$notes_temporary_directory" || -L "$notes_temporary_directory" ]]; then
    print -u2 -- "$notes_label temporary directory is missing or unsafe"
    return 1
  fi
  if ! notes_extraction_directory="$(
    mktemp -d "$notes_temporary_directory/internal-display-name.XXXXXX"
  )"; then
    print -u2 -- "$notes_label temporary output could not be created"
    return 1
  fi
  if ! chmod 700 "$notes_extraction_directory"; then
    print -u2 -- "$notes_label temporary output permissions could not be secured"
    return 1
  fi
  notes_raw_path="$notes_extraction_directory/value.raw"
  if ! plutil -extract "$notes_plist_key" raw -expect string \
    -o "$notes_raw_path" "$notes_plist_path" >/dev/null 2>&1
  then
    print -u2 -- "$notes_label is missing or is not a string"
    return 1
  fi
  if [[ ! -f "$notes_raw_path" || -L "$notes_raw_path" ]]; then
    print -u2 -- "$notes_label could not be read safely"
    return 1
  fi
  if ! chmod 600 "$notes_raw_path"; then
    print -u2 -- "$notes_label raw output permissions could not be secured"
    return 1
  fi

  IFS= read -r -d '' notes_value < "$notes_raw_path" || true
  notes_validate_internal_display_name_file "$notes_raw_path" "$notes_label" || return 1
  printf -v "$notes_result_variable" '%s' "$notes_value" || return 1
  printf -v "$notes_raw_path_variable" '%s' "$notes_raw_path" || return 1
}

notes_read_internal_placeholder_display_name() {
  local notes_result_variable="$4"
  local notes_label="${6:-Internal display name}"
  local notes_expected_bundle_identifier="$7"
  local notes_product_name
  local notes_expected_internal_display_name

  notes_product_name="${notes_expected_bundle_identifier##*.}"
  if [[ "$notes_product_name" == "$notes_expected_bundle_identifier" \
    || ! "$notes_product_name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]
  then
    print -u2 -- "$notes_label stable bundle identifier is invalid"
    return 1
  fi
  notes_expected_internal_display_name="${notes_product_name} Dev"

  notes_read_validated_display_name "${@:1:6}" || return 1
  if [[ "${(P)notes_result_variable}" != "$notes_expected_internal_display_name" ]]; then
    print -u2 -- "$notes_label is not the internal placeholder derived from stable identity"
    return 1
  fi
}

notes_assert_no_localized_display_name_override() {
  local notes_tree_path="$1"
  local notes_temporary_directory="$2"
  local notes_label="${3:-App bundle}"
  local notes_listing_directory
  local notes_listing_path
  local notes_strings_path

  if [[ ! -d "$notes_tree_path" || -L "$notes_tree_path" ]]; then
    print -u2 -- "$notes_label localization root is missing or unsafe"
    return 1
  fi
  if [[ ! -d "$notes_temporary_directory" || -L "$notes_temporary_directory" ]]; then
    print -u2 -- "$notes_label temporary directory is missing or unsafe"
    return 1
  fi
  if ! notes_listing_directory="$(
    mktemp -d "$notes_temporary_directory/display-name-localizations.XXXXXX"
  )"; then
    print -u2 -- "$notes_label localization listing could not be created"
    return 1
  fi
  if ! chmod 700 "$notes_listing_directory"; then
    print -u2 -- "$notes_label localization listing permissions could not be secured"
    return 1
  fi
  notes_listing_path="$notes_listing_directory/paths.nul"
  if ! find "$notes_tree_path" -name InfoPlist.strings -print0 > "$notes_listing_path"; then
    print -u2 -- "$notes_label localization tree could not be inspected"
    return 1
  fi
  if ! chmod 600 "$notes_listing_path"; then
    print -u2 -- "$notes_label localization listing permissions could not be secured"
    return 1
  fi

  while IFS= read -r -d '' notes_strings_path; do
    if [[ ! -f "$notes_strings_path" || -L "$notes_strings_path" ]]; then
      print -u2 -- "$notes_label contains an unsafe InfoPlist.strings path"
      return 1
    fi
    if ! plutil -lint "$notes_strings_path" >/dev/null 2>&1; then
      print -u2 -- "$notes_label contains an invalid InfoPlist.strings file"
      return 1
    fi
    if plutil -extract CFBundleDisplayName raw -o - \
      "$notes_strings_path" >/dev/null 2>&1
    then
      print -u2 -- "$notes_label contains a localized display-name override"
      return 1
    fi
  done < "$notes_listing_path"
}
