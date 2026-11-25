# shellcheck shell=bash
# Defines select_tests, fallback_selection, and test_filters, which bin/test
# sources to run only the tests that a change can affect. Run them from the
# package root.
#
# A test can depend on a changed file in two ways. Its target can link the
# file's target, which the package's target graph shows. Or the test can read
# the file at run time: fixtures, bin/ scripts, and Sources/ itself, which
# SourceAuditTests scans. When the rules below cannot show which tests a file
# reaches, they select whole test targets outside ci_only_targets and the smoke
# suites, never nothing. They never select a whole ci_only_targets target.

# CI runs every test that a change can affect once its PR is ready for
# review. Locally these targets run only a changed file's own suites, the
# suites of the test files that use its names or quote its path, and the smoke
# suites. The search does not follow the files that use those test files. The
# tests of these targets start sbd and tmux, so they take most of the suite's
# run time.
ci_only_targets=" IntegrationTests "

# A changed file that more test files of a ci-only target use than this runs
# the smoke suites in place of those files.
max_user_files=10

# Lists the smoke suites, one Target.Suite per line. Lines that start with #
# are comments.
smoke_file=Tests/smoke-suites

is_ci_only() {
  case $ci_only_targets in *" $1 "*) return 0 ;; esac
  return 1
}

# Matches a Markdown file at the repository root, which no build or test reads.
root_markdown='^[^/]+\.md$'

# Prints the paths on stdin, one per line, of the files whose text matches the
# grep arguments.
files_matching() {
  tr '\n' '\0' | xargs -0 grep -l "$@" 2>/dev/null | sort || true
}

# folder_readers <folder> <dir>…
# Prints the Swift files under the dirs that read the repo's <folder> at run
# time. Such a file finds the repo root through #filePath or Instance.root and
# names <folder> as a path in a string.
folder_readers() {
  local folder=$1
  shift
  find "$@" -name '*.swift' | files_matching -E '#filePath|Instance\.root' |
    files_matching -E "[\"/]$folder([/\"]|\$)"
}

ere_escape() {
  sed 's/[][\.*^$+?(){}|]/\\&/g' <<<"$1"
}

# Prints the smoke suites as select_tests lines, one per target. Each line has
# a count of 0, which tells test_filters to skip its listing check.
smoke_selection() {
  if [ ! -f "$smoke_file" ]; then
    echo "bin/test: $smoke_file is missing, so no smoke suites run" >&2
    return 0
  fi
  awk -F. '/^#/ || NF != 2 { next } { s[$1] = s[$1] " " $2 } END { for (t in s) print "suites " t " 0" s[t] }' \
    "$smoke_file"
}

# target_graph <package-json>
# Prints one line per target of the package that swift package dump-package
# printed: name, type, folder, excluded folders, and the targets it depends
# on, separated by tabs, with lists joined by commas.
target_graph() {
  jq -r '.targets[] | [
    .name, .type,
    ((.path // ((if .type == "test" then "Tests/" else "Sources/" end) + .name)) | rtrimstr("/")),
    ((.exclude // []) | join(",")),
    ([.dependencies[] | (.byName // .target // empty)[0]] | join(","))
  ] | @tsv' <<<"$1"
}

# path_target <graph> <path>
# Prints the target_graph line of the target whose folder holds <path>, the
# innermost one when folders nest, and nothing when no folder holds it.
path_target() {
  awk -F'\t' -v p="$2" 'index(p, $3 "/") == 1 { print length($3) "\t" $0 }' <<<"$1" |
    sort -rn | sed -n $'1s/^[0-9]*\t//p'
}

# excluded_path <path> <target-dir> <excludes>
# Succeeds when <path> sits in one of the target's excluded folders, which
# <excludes> lists relative to <target-dir>, joined by commas.
excluded_path() {
  local e ex
  IFS=, read -r -a ex <<<"$3"
  for e in ${ex[@]+"${ex[@]}"}; do
    case $1 in "$2/$e" | "$2/$e/"*) return 0 ;; esac
  done
  return 1
}

# dependent_tests <graph> <target>…
# Prints the test targets that are one of the targets or depend on one,
# directly or through other targets.
dependent_tests() {
  local graph=$1
  shift
  awk -F'\t' -v changed="$*" '
    { type[$1] = $2; deps[$1] = $5 }
    END {
      n = split(changed, c, " ")
      for (i = 1; i <= n; i++) hit[c[i]] = 1
      do {
        more = 0
        for (t in deps) {
          if (t in hit) continue
          m = split(deps[t], d, ",")
          for (j = 1; j <= m; j++) if (d[j] in hit) { hit[t] = 1; more = 1; break }
        }
      } while (more)
      for (t in hit) if (type[t] == "test") print t
    }' <<<"$graph"
}

# select_tests <package-json> [unknown]
# Reads changed paths, one per line, on stdin. <package-json> is the text that
# swift package dump-package prints. With "unknown", it also selects what a
# path that no rule maps selects. Prints one line per selection:
#   target <T>                   test target T
#   suites <T> <count> <name>…   the top-level types of one test file of T,
#                                which has <count> @Test attributes
# Prints nothing when no test can read a changed path. Says on stderr what
# each path selects.
select_tests() {
  local graph changed found name type dir excludes deps
  local unknown=${2:-} smoke= sources= whole_targets=" " seen=" " suites=() file line reached
  graph=$(target_graph "$1") || return 1

  add_test_file() {
    case $whole_targets in *" $1 "*) return ;; esac
    case $seen in *" $3 "*) return ;; esac
    seen+="$3 "
    line=$(test_file_selection "$1" "$2" "$3")
    if [[ $line != target* ]]; then
      suites+=("$line")
    elif is_ci_only "$1"; then
      add_ci_only_file "$1" "$2" "$3"
    else
      whole_targets+="$1 "
    fi
  }

  # add_file_suites <target> <file> [<decls>]
  # Selects the suites of a test file. A file whose tests have no type adds the
  # smoke suites, because a suite filter cannot name those tests.
  add_file_suites() {
    local line
    line=$(file_suites "$@")
    if [ -n "$line" ]; then
      suites+=("$line")
    elif grep -q '@Test' "$2"; then
      echo "bin/test: $2: its tests have no type to filter by, so the smoke suites run" >&2
      smoke=1
    fi
  }

  # add_user_files <target> <changed> <files>
  # Selects the suites of <files>, one path per line, which use <changed>. When
  # there are more than max_user_files, selects the smoke suites instead.
  add_user_files() {
    local n file
    n=$(grep -c . <<<"$3" || true)
    if [ "$n" -gt "$max_user_files" ]; then
      echo "bin/test: $2: $n $1 test files use it, more than $max_user_files, so the smoke suites run in their place" >&2
      smoke=1
      return
    fi
    [ "$n" -gt 0 ] || return 0
    echo "bin/test: $2: runs the suites of the $n $1 test files that use it:" $3 >&2
    while IFS= read -r file; do add_file_suites "$1" "$file"; done <<<"$3"
  }

  # add_ci_only_file <target> <target-dir> <file>
  # Selects a ci-only test file that test_file_selection cannot narrow: its own
  # suites, and the suites of the target's other test files that name one of
  # its non-private top-level names. A deleted file, a file with a top-level
  # line that the parse cannot read, a file with a non-private extension, and a
  # file without tests whose names no other test file uses add the smoke
  # suites.
  add_ci_only_file() {
    local decls names users
    if [ ! -f "$3" ]; then
      echo "bin/test: $3: the smoke suites run in its place" >&2
      smoke=1
      return
    fi
    decls=$(top_level_decls "$3")
    add_file_suites "$1" "$3" "$decls"
    if grep -qx unreadable <<<"$decls"; then
      echo "bin/test: $3: the smoke suites run, because the selector cannot read every name it declares" >&2
      smoke=1
      return
    fi
    # Other files call an extension's members without naming the extended type.
    if grep -q '^extension .* 0$' <<<"$decls"; then
      echo "bin/test: $3: the smoke suites run, because other files can use what its extensions add without naming the type" >&2
      smoke=1
    fi
    names=$(awk '$3 == 0 { print $2 }' <<<"$decls" | sort -u | paste -sd'|' -)
    users=
    if [ -n "$names" ]; then
      users=$(find "$2" -name '*.swift' | grep -vxF -- "$3" | files_matching -wE -- "($names)" |
        files_matching '@Test') || true
    fi
    if [ -z "$users" ] && ! grep -q '@Test' "$3"; then
      echo "bin/test: $3: no other $1 test file uses its names, so the smoke suites run" >&2
      smoke=1
      return
    fi
    add_user_files "$1" "$3" "$users"
  }

  # add_naming_files <changed> <in-test-target>
  # Selects the suites of the ci-only test files that name <changed>, a path
  # that no rule maps, such as a fixture or a bin/ script. A file names it by
  # its repo path, or by its file name when <in-test-target> is set.
  add_naming_files() {
    local terms pattern users name type dir excludes deps
    terms=$(ere_escape "$1")
    [ -z "$2" ] || terms+="|$(ere_escape "${1##*/}")"
    pattern="(^|[^A-Za-z0-9_.-])($terms)([^A-Za-z0-9_.-]|\$)"
    while IFS=$'\t' read -r name type dir excludes deps; do
      [ "$type" = test ] && is_ci_only "$name" || continue
      users=$(find "$dir" -name '*.swift' | grep -vxF -- "$1" | files_matching -E -- "$pattern" |
        files_matching '@Test') || true
      add_user_files "$name" "$1" "$users"
    done <<<"$graph"
  }

  while IFS= read -r changed; do
    [ -n "$changed" ] || continue
    if [[ $changed =~ $root_markdown ]]; then
      echo "bin/test: $changed: no test reads it" >&2
      continue
    fi
    found=$(path_target "$graph" "$changed")
    if [ -z "$found" ]; then
      echo "bin/test: $changed: outside every target, so the unit test targets and the smoke suites run" >&2
      unknown=1
      add_naming_files "$changed" ""
      continue
    fi
    IFS=$'\t' read -r name type dir excludes deps <<<"$found"
    if [[ $changed != *.swift ]] || excluded_path "$changed" "$dir" "$excludes"; then
      echo "bin/test: $changed: tests can read it at run time, so the unit test targets and the smoke suites run" >&2
      unknown=1
      add_naming_files "$changed" "$([ "$type" = test ] && echo 1)"
    elif [ "$type" = test ]; then
      add_test_file "$name" "$dir" "$changed"
    else
      echo "bin/test: $changed: runs the test targets that depend on $name" >&2
      sources+="$name "
    fi
  done

  if [ -n "$sources" ]; then
    reached=$(dependent_tests "$graph" $sources)
    for name in $reached; do
      if is_ci_only "$name"; then
        echo "bin/test: leaves $name to CI for source changes" >&2
      else
        whole_targets+="$name "
      fi
    done
    # A test file reads source files at run time when it finds the repo root
    # through #filePath or Instance.root and names a Sources path in a string.
    # Tests that pass made-up paths such as "/tmp/x/Sources" do neither.
    while IFS=$'\t' read -r name type dir excludes deps; do
      [ "$type" = test ] || continue
      case "$whole_targets$ci_only_targets" in *" $name "*) continue ;; esac
      while IFS= read -r file; do
        [ -n "$file" ] || continue
        echo "bin/test: $file reads Sources/ at run time" >&2
        add_test_file "$name" "$dir" "$file"
      done < <(folder_readers Sources "$dir")
    done <<<"$graph"
  fi

  if [ -n "$unknown" ]; then
    while IFS=$'\t' read -r name type _; do
      [ "$type" != test ] || whole_targets+="$name "
    done <<<"$graph"
  fi
  # This is the one place that keeps a whole ci-only target out of the output.
  for name in $whole_targets; do
    if is_ci_only "$name"; then smoke=1; fi
  done
  {
    for name in $whole_targets; do is_ci_only "$name" || echo "target $name"; done
    for line in ${suites[@]+"${suites[@]}"}; do
      read -r _ name _ <<<"$line"
      case $whole_targets in *" $name "*) is_ci_only "$name" || continue ;; esac
      echo "$line"
    done
    [ -z "$smoke" ] || smoke_selection
  } | sort -u
}

# fallback_selection <package-json>
# Prints the select_tests lines for a change that bin/test cannot list: every
# test target outside ci_only_targets, and the smoke suites.
fallback_selection() {
  select_tests "$1" unknown </dev/null
}

# top_level_decls <file>
# Prints "<kind> <name> <private>" for each top-level declaration. A line that
# starts in column 0 with a letter or an attribute is top level. Prints
# "unreadable" for a `#if`, which can hide an indented declaration, and for a
# top-level line with no name to read, such as `extension [K: V]`.
top_level_decls() {
  awk '
    /^#if/ { print "unreadable"; next }
    /^[A-Za-z@]/ && !/^import / {
      if (!match($0, /(^|[ )])(struct|class|enum|actor|extension|protocol|typealias|func|let|var)[ ]+[A-Za-z_][A-Za-z0-9_.]*/)) {
        if (!/^@/ || /(^|[ )])(struct|class|enum|actor|extension|protocol|typealias|func|let|var)[ ]/) print "unreadable"
        next
      }
      decl = substr($0, RSTART, RLENGTH)
      prefix = substr($0, 1, RSTART)
      sub(/^[ )]/, "", decl)
      split(decl, w, /[ ]+/)
      name = w[2]
      sub(/\..*/, "", name)
      print w[1], name, (prefix ~ /(^|[ ])(private|fileprivate)[ ]/) ? 1 : 0
    }' "$1"
}

# suite_names <decls>
# Prints the names of the types and extensions that top_level_decls printed, on
# one line.
suite_names() {
  awk '$1 ~ /^(struct|class|enum|actor|extension)$/ { print $2 }' <<<"$1" | sort -u | paste -sd' ' -
}

# file_suites <target> <file> [<decls>]
# Prints "suites <target> <count> <name>…" for the top-level types of a test
# file with <count> @Test attributes, and nothing for a file without tests or
# types. <decls> is the file's top_level_decls output, when the caller has it.
file_suites() {
  local count names
  count=$(grep -c '@Test' "$2" || true)
  [ "$count" -gt 0 ] || return 0
  names=$(suite_names "${3-$(top_level_decls "$2")}")
  [ -z "$names" ] || echo "suites $1 $count $names"
}

# test_file_selection <target> <target-dir> <file>
# Prints "suites <target> <count> <name>…" when the file's tests can be run on
# their own, and "target <target>" when they cannot. They cannot when the file
# is gone, declares no tests, declares a test outside a type, or declares no
# type. They also cannot when a non-private extension in the file extends a
# type that the target does not declare, because other files can call what it
# adds. Last, they cannot when another file of the target names one of the
# file's non-private top-level names other than as "extension <name>".
test_file_selection() {
  local target=$1 dir=$2 file=$3 count decls suites files others names used extended
  whole() {
    if is_ci_only "$target"; then
      echo "bin/test: $file: $1" >&2
    else
      echo "bin/test: $file: $1, so all of $target runs" >&2
    fi
    echo "target $target"
  }
  [ -f "$file" ] || { whole "it was deleted"; return; }
  count=$(grep -c '@Test' "$file" || true)
  [ "$count" -gt 0 ] || { whole "it declares no tests"; return; }
  grep -q '^@Test' "$file" && { whole "it declares a test outside a type"; return; }
  decls=$(top_level_decls "$file")
  if grep -qx unreadable <<<"$decls"; then
    whole "it has a top-level line that the selector cannot read"
    return
  fi
  suites=$(suite_names "$decls")
  [ -n "$suites" ] || { whole "it declares no type"; return; }

  files=$(find "$dir" -name '*.swift' | sort)
  others=$(grep -vxF -- "$file" <<<"$files" || true)
  # The listing shows tests that other files add to these suites through
  # extensions, so count them too. A block ends only at a `}` in column 0. An
  # indented extension therefore counts to the end of its file, and the larger
  # count can only widen the selection.
  if [ -n "$others" ]; then
    extended=$(tr '\n' '\0' <<<"$others" |
      xargs -0 awk -v re="(^|[^A-Za-z0-9_])extension[ ]+([A-Za-z_][A-Za-z0-9_]*[.])?(${suites// /|})([^A-Za-z0-9_]|$)" '
        FNR == 1 { inside = 0 }
        $0 ~ re { inside = 1 }
        inside && /@Test/ { n++ }
        /^}/ { inside = 0 }
        END { print n + 0 }' |
      awk '{ s += $1 } END { print s + 0 }')
    count=$((count + extended))
  fi
  names=$(awk '$3 == 0 { print $2 }' <<<"$decls" | sort -u)
  used=$(
    {
      awk '$1 == "extension" && $3 == 0 { print "extends", $2 }' <<<"$decls"
      tr '\n' '\0' <<<"$files" |
        xargs -0 grep -ohE '(^|[ )])(struct|class|enum|actor)[ ]+[A-Za-z_][A-Za-z0-9_]*' 2>/dev/null |
        awk '{ print "declares", $NF }'
      if [ -n "$names" ] && [ -n "$others" ]; then
        tr '\n' '\0' <<<"$others" |
          xargs -0 grep -hwE -- "($(tr '\n' '|' <<<"$names" | sed 's/|$//'))" 2>/dev/null |
          sed 's/^/line /'
      fi
    } | awk -v names="$(tr '\n' ' ' <<<"$names")" '
      $1 == "extends" { extended[$2] = 1; next }
      $1 == "declares" { declared[$2] = 1; next }
      {
        line = substr($0, 6)
        n = split(names, w, " ")
        for (i = 1; i <= n; i++) {
          if (line !~ ("(^|[^A-Za-z0-9_])" w[i] "([^A-Za-z0-9_]|$)")) continue
          if (line ~ ("^extension " w[i] "([^A-Za-z0-9_]|$)")) continue
          if (!(w[i] in usedby)) usedby[w[i]] = 1
        }
      }
      END {
        for (e in extended) if (!(e in declared)) { print "extends " e; exit }
        for (u in usedby) { print "uses " u; exit }
      }'
  )
  case $used in
  extends*) whole "it extends ${used#extends }, which $target does not declare" ;;
  uses*) whole "another file uses its ${used#uses }" ;;
  *)
    echo "bin/test: $file: runs $suites" >&2
    echo "suites $target $count $suites"
    ;;
  esac
}

# selection_targets
# Reads select_tests lines on stdin and prints the test targets they name, one
# per line.
selection_targets() {
  awk '$1 == "target" || $1 == "suites" { print $2 }' | sort -u
}

# filter_targets
# Reads test_filters patterns on stdin and prints the test targets they name,
# one per line. Every pattern starts with ^<target>\.
filter_targets() {
  sed -n -E 's/^\^([A-Za-z0-9_]+)\\\..*/\1/p' | sort -u
}

# test_filters
# Reads select_tests lines on stdin and prints one --filter pattern for each.
# A file's suites become a pattern only when list_tests shows that it matches
# at least as many tests as the file and other files' extensions of its suites
# declare. Otherwise they become their whole target, so a declaration that the
# parse missed still runs. A ci-only target keeps the pattern and adds the
# smoke suites instead. A count of 0 skips the check.
test_filters() {
  local kind target count names pattern list= matched
  {
    while read -r kind target count names; do
      case $kind in
      target) echo "^$target\\." ;;
      suites)
        pattern="^$target\\.(${names// /|})/"
        if [ "$count" -eq 0 ]; then
          echo "$pattern"
          continue
        fi
        [ -n "$list" ] || list=$(list_tests) || true
        matched=$(grep -c -E "$pattern" <<<"$list" || true)
        if [ "$matched" -ge "$count" ]; then
          echo "$pattern"
        elif is_ci_only "$target"; then
          echo "bin/test: $pattern matches $matched tests, fewer than the $count its suites declare, so the smoke suites run too" >&2
          echo "$pattern"
          smoke_selection | test_filters
        else
          echo "bin/test: $pattern matches $matched tests, fewer than the $count its suites declare, so all of $target runs" >&2
          echo "^$target\\."
        fi
        ;;
      esac
    done
  } | sort -u
}
