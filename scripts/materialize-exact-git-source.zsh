#!/bin/zsh
set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

notes_repository_path=""
notes_commit=""
notes_destination_path=""
notes_temp_dir=""
notes_destination_created=0

usage() {
  cat <<'EOF'
Usage: scripts/materialize-exact-git-source.zsh --repository <path> --commit <oid> --destination <path>

Materialize one exact Git commit into a new private directory. Replacement
objects and repository, user, or system attribute overrides are excluded. The
result is accepted only after every regular file's object ID and mode match the
commit tree.
EOF
}

fail() {
  print -u2 -- "$1"
  exit 1
}

cleanup() {
  if (( notes_destination_created == 1 )); then
    chmod -R u+w "$notes_destination_path" 2>/dev/null || true
    rm -rf "$notes_destination_path" 2>/dev/null || true
    notes_destination_created=0
  fi
  if [[ -n "$notes_temp_dir" ]]; then
    chmod -R u+w "$notes_temp_dir" 2>/dev/null || true
    rm -rf "$notes_temp_dir" 2>/dev/null || true
    notes_temp_dir=""
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --repository)
      (( $# >= 2 )) || fail "--repository requires a path"
      notes_repository_path="$2"
      shift 2
      ;;
    --commit)
      (( $# >= 2 )) || fail "--commit requires an object ID"
      notes_commit="$2"
      shift 2
      ;;
    --destination)
      (( $# >= 2 )) || fail "--destination requires a path"
      notes_destination_path="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ -n "$notes_repository_path" ]] || fail "--repository is required"
[[ -n "$notes_commit" ]] || fail "--commit is required"
[[ -n "$notes_destination_path" ]] || fail "--destination is required"
[[ -x /usr/bin/git ]] || fail "Apple Git is required"
[[ -x /usr/bin/tar ]] || fail "Apple tar is required"
[[ -x /usr/bin/stat ]] || fail "stat is required"
[[ -x /usr/bin/perl ]] || fail "Perl is required"

umask 077
notes_repository_path="$(cd "$notes_repository_path" 2>/dev/null && pwd -P)" \
  || fail "Repository directory not found"
notes_destination_parent="$(cd "${notes_destination_path:h}" 2>/dev/null && pwd -P)" \
  || fail "Destination parent directory not found"
[[ -O "$notes_destination_parent" ]] || fail "Destination parent is not owned by this user"
notes_destination_parent_mode="$(/usr/bin/stat -f '%Lp' "$notes_destination_parent")" \
  || fail "Unable to read destination parent permissions"
[[ "$notes_destination_parent_mode" == <-> ]] \
  || fail "Destination parent permissions are invalid"
[[ "$notes_destination_parent_mode" == "700" ]] \
  || fail "Destination parent must be a private 0700 directory"
notes_destination_name="${notes_destination_path:t}"
[[ -n "$notes_destination_name" && "$notes_destination_name" != "." \
  && "$notes_destination_name" != ".." ]] || fail "Destination name is invalid"
notes_destination_path="$notes_destination_parent/$notes_destination_name"
[[ ! -e "$notes_destination_path" && ! -L "$notes_destination_path" ]] \
  || fail "Destination already exists"

notes_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inknotes-exact-source.XXXXXX")"
chmod 700 "$notes_temp_dir"
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
mkdir -m 700 \
  "$notes_temp_dir/home" \
  "$notes_temp_dir/xdg" \
  "$notes_temp_dir/tmp" \
  "$notes_temp_dir/empty-template"

notes_repository_git() {
  /usr/bin/env -i \
    HOME="$notes_temp_dir/home" \
    XDG_CONFIG_HOME="$notes_temp_dir/xdg" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR="$notes_temp_dir/tmp" \
    LC_ALL=C \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_OPTIONAL_LOCKS=0 \
    /usr/bin/git --no-replace-objects -C "$notes_repository_path" "$@"
}

notes_object_format="$(notes_repository_git rev-parse --show-object-format)" \
  || fail "Unable to read the repository object format"
case "$notes_object_format" in
  sha1) notes_object_id_length=40 ;;
  sha256) notes_object_id_length=64 ;;
  *) fail "Unsupported Git object format" ;;
esac
[[ "$notes_commit" =~ "^[0-9a-f]{$notes_object_id_length}$" ]] \
  || fail "Commit must be one full lowercase object ID"
notes_resolved_commit="$(notes_repository_git rev-parse --verify "${notes_commit}^{commit}")" \
  || fail "Commit cannot be resolved without replacement objects"
[[ "$notes_resolved_commit" == "$notes_commit" ]] \
  || fail "Commit did not resolve to the exact requested object ID"

notes_object_directory="$(
  notes_repository_git rev-parse --path-format=absolute --git-path objects
)" || fail "Unable to locate the repository object database"
[[ "$notes_object_directory" == /* && -d "$notes_object_directory" ]] \
  || fail "Repository object database is unavailable"

notes_isolated_git_dir="$notes_temp_dir/source-view.git"
/usr/bin/env -i \
  HOME="$notes_temp_dir/home" \
  XDG_CONFIG_HOME="$notes_temp_dir/xdg" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  TMPDIR="$notes_temp_dir/tmp" \
  LC_ALL=C \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_SYSTEM=/dev/null \
  /usr/bin/git init --quiet --bare \
    --template="$notes_temp_dir/empty-template" \
    --object-format="$notes_object_format" \
    "$notes_isolated_git_dir" \
  || fail "Unable to initialize the isolated Git metadata view"
[[ ! -e "$notes_isolated_git_dir/info/attributes" ]] \
  || fail "Isolated Git metadata unexpectedly contains attributes"

notes_exact_git() {
  /usr/bin/env -i \
    HOME="$notes_temp_dir/home" \
    XDG_CONFIG_HOME="$notes_temp_dir/xdg" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR="$notes_temp_dir/tmp" \
    LC_ALL=C \
    GIT_DIR="$notes_isolated_git_dir" \
    GIT_OBJECT_DIRECTORY="$notes_object_directory" \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=0 \
    GIT_OPTIONAL_LOCKS=0 \
    /usr/bin/git --no-replace-objects \
      -c core.attributesFile=/dev/null \
      -c tar.umask=0022 \
      "$@"
}

notes_manifest="$notes_temp_dir/tree.manifest"
notes_exact_git ls-tree -rz --full-tree "$notes_commit" > "$notes_manifest" \
  || fail "Unable to read the exact commit tree"
chmod 600 "$notes_manifest"
if ! /usr/bin/perl -0 -e '
  use strict;
  use warnings;
  use Encode qw(decode FB_CROAK);
  use Unicode::Normalize qw(NFD);
  use feature qw(fc);
  my %normalized_paths;
  while (defined(my $entry = <>)) {
    $entry =~ s/\0\z// or die "tree manifest record is not NUL terminated\n";
    $entry =~ /\A([0-9]{6}) ([a-z]+) ([0-9a-f]+)\t(.*)\z/s
      or die "tree manifest record is malformed\n";
    my ($mode, $type, $path) = ($1, $2, $4);
    die "tracked symbolic links and submodules are unsupported\n"
      if $mode eq "120000" || $mode eq "160000";
    die "unsupported Git tree entry mode\n"
      unless $type eq "blob" && ($mode eq "100644" || $mode eq "100755");
    my @parts = split(m{/}, $path, -1);
    die "unsafe Git tree path\n"
      if $path eq "" || substr($path, 0, 1) eq "/"
        || grep { $_ eq "" || $_ eq "." || $_ eq ".." } @parts;
    die "committed .gitattributes requires explicit snapshot review\n"
      if grep { $_ eq ".gitattributes" } @parts;
    my $decoded_path = decode("UTF-8", $path, FB_CROAK);
    my $normalized_path = NFD(fc($decoded_path));
    die "case-folding or Unicode-normalization path collision\n"
      if exists $normalized_paths{$normalized_path}
        && $normalized_paths{$normalized_path} ne $decoded_path;
    $normalized_paths{$normalized_path} = $decoded_path;
  }
' "$notes_manifest"
then
  fail "Exact commit tree is unsafe to materialize"
fi

notes_exact_git read-tree "$notes_commit" \
  || fail "Unable to prepare the isolated attribute index"
notes_index_paths="$notes_temp_dir/index-paths"
notes_attributes="$notes_temp_dir/attributes"
notes_exact_git ls-files -z > "$notes_index_paths" \
  || fail "Unable to enumerate the isolated attribute index"
notes_exact_git check-attr --cached -z --stdin export-ignore export-subst \
  < "$notes_index_paths" > "$notes_attributes" \
  || fail "Unable to verify isolated Git attributes"
chmod 600 "$notes_index_paths" "$notes_attributes"
if ! /usr/bin/perl -0 -e '
  use strict;
  use warnings;
  my @fields;
  while (defined(my $field = <>)) {
    $field =~ s/\0\z// or die "attribute record is not NUL terminated\n";
    push @fields, $field;
  }
  die "attribute record is malformed\n" if @fields % 3;
  for (my $index = 0; $index < @fields; $index += 3) {
    die "archive attribute source was not fully isolated\n"
      unless $fields[$index + 1] eq "export-ignore"
        || $fields[$index + 1] eq "export-subst";
    die "archive attribute source was not fully isolated\n"
      unless $fields[$index + 2] eq "unspecified";
  }
' "$notes_attributes"
then
  fail "Archive attributes were not fully isolated"
fi

notes_archive="$notes_temp_dir/source.tar"
notes_exact_git archive --format=tar --output="$notes_archive" "$notes_commit" \
  || fail "Unable to archive the exact commit"
[[ -f "$notes_archive" && ! -L "$notes_archive" ]] \
  || fail "Exact source archive was not produced safely"
chmod 600 "$notes_archive"

mkdir -m 700 "$notes_destination_path" \
  || fail "Unable to create the new destination directory"
notes_destination_created=1
/usr/bin/env -i \
  HOME="$notes_temp_dir/home" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  TMPDIR="$notes_temp_dir/tmp" \
  LC_ALL=C \
  /usr/bin/tar -xpf "$notes_archive" -C "$notes_destination_path" \
  || fail "Unable to extract the exact source archive"

notes_expected_file_count=0
while IFS= read -r -d '' notes_tree_entry; do
  notes_metadata="${notes_tree_entry%%$'\t'*}"
  notes_relative_path="${notes_tree_entry#*$'\t'}"
  notes_mode="${notes_metadata%% *}"
  notes_object_id="${notes_metadata##* }"
  notes_materialized_path="$notes_destination_path/$notes_relative_path"
  [[ -f "$notes_materialized_path" && ! -L "$notes_materialized_path" ]] \
    || fail "Materialized source is missing an exact regular file"
  notes_actual_object_id="$(
    notes_exact_git hash-object --no-filters "$notes_materialized_path"
  )" || fail "Unable to hash a materialized source file"
  [[ "$notes_actual_object_id" == "$notes_object_id" ]] \
    || fail "Materialized source file bytes differ from the exact commit"
  notes_actual_mode="$(/usr/bin/stat -f '%Lp' "$notes_materialized_path")" \
    || fail "Unable to read a materialized source file mode"
  case "$notes_mode" in
    100644) [[ "$notes_actual_mode" == "644" ]] \
      || fail "Materialized non-executable file mode differs from the exact commit" ;;
    100755) [[ "$notes_actual_mode" == "755" ]] \
      || fail "Materialized executable file mode differs from the exact commit" ;;
    *) fail "Materialized source contains an unsupported file mode" ;;
  esac
  (( notes_expected_file_count += 1 ))
done < "$notes_manifest"

notes_actual_file_count="$(
  find "$notes_destination_path" -type f -print0 \
    | /usr/bin/perl -0ne '$count += 1; END { print $count // 0 }'
)" || fail "Unable to count materialized source files"
[[ "$notes_actual_file_count" == "$notes_expected_file_count" ]] \
  || fail "Materialized source contains missing or extra files"
if find "$notes_destination_path" ! -type d ! -type f -print -quit | grep -q .; then
  fail "Materialized source contains an unsupported filesystem entry"
fi

notes_destination_created=0
print -- "Exact Git source materialized: $notes_destination_path"
