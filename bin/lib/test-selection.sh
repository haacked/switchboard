# shellcheck shell=bash
# Defines select_tests and test_filters, which bin/test sources to run only
# the tests that a change can affect. Run them from the package root.
#
# A test can depend on a changed file in two ways. Its target can link the
# file's target, which the package's target graph shows. Or the test can read
# the file at run time: fixtures, bin/ scripts, and Sources/ itself, which
# SourceAuditTests scans. When the rules below cannot show which tests a file
# reaches, they select a whole test target or every test, never nothing.

# A source change leaves these test targets to CI, which runs every test.
# Their tests start sbd and tmux, so they take most of the suite's run time. A
# change to one of their own files, or to a file that selects every test,
# still runs them here.
ci_only_targets=" IntegrationTests "

# select_tests <package-json>
# Reads changed paths, one per line, on stdin. <package-json> is the text that
# swift package dump-package prints. Prints one line per selection:
#   all                          every test
#   target <T>                   test target T
#   suites <T> <count> <name>…   the top-level types of one test file of T,
#                                which has <count> @Test attributes
# Prints nothing when no test can read a changed path. Says on stderr what
# each path selects.
select_tests() {
  local graph changed found name type dir excludes deps e ex excluded
  local all= sources= whole_targets=" " seen=" " suites=() tests file line missing= reached
  # One line per target: name, type, folder, excluded folders, and the targets
  # it depends on, with lists joined by commas.
  graph=$(jq -r '.targets[] | [
      .name, .type,
      ((.path // ((if .type == "test" then "Tests/" else "Sources/" end) + .name)) | rtrimstr("/")),
      ((.exclude // []) | join(",")),
      ([.dependencies[] | (.byName // .target // empty)[0]] | join(","))
    ] | @tsv' <<<"$1") || return 1

  add_test_file() {
    case $whole_targets in *" $1 "*) return ;; esac
    case $seen in *" $3 "*) return ;; esac
    seen+="$3 "
    line=$(test_file_selection "$1" "$2" "$3")
    if [[ $line == target* ]]; then whole_targets+="$1 "; else suites+=("$line"); fi
  }

  while IFS= read -r changed; do
    [ -n "$changed" ] && [ -z "$all" ] || continue
    if [[ $changed =~ ^[^/]+\.md$ ]]; then
      echo "bin/test: $changed: no test reads it" >&2
      continue
    fi
    found=$(awk -F'\t' -v p="$changed" 'index(p, $3 "/") == 1 { print length($3) "\t" $0 }' <<<"$graph" |
      sort -rn | sed -n $'1s/^[0-9]*\t//p')
    if [ -z "$found" ]; then
      echo "bin/test: $changed: outside every target, so every test runs" >&2
      all=1
      continue
    fi
    IFS=$'\t' read -r name type dir excludes deps <<<"$found"
    excluded=
    IFS=, read -r -a ex <<<"$excludes"
    for e in ${ex[@]+"${ex[@]}"}; do
      case $changed in "$dir/$e" | "$dir/$e/"*) excluded=1 ;; esac
    done
    if [[ $changed != *.swift ]] || [ -n "$excluded" ]; then
      echo "bin/test: $changed: tests can read it at run time, so every test runs" >&2
      all=1
    elif [ "$type" = test ]; then
      add_test_file "$name" "$dir" "$changed"
    else
      echo "bin/test: $changed: runs the test targets that depend on $name" >&2
      sources+="$name "
    fi
  done
  if [ -n "$all" ]; then
    echo all
    return
  fi

  tests=$(awk -F'\t' '$2 == "test" { print $1 }' <<<"$graph")
  if [ -n "$sources" ]; then
    reached=$(awk -F'\t' -v changed="$sources" '
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
      }' <<<"$graph")
    for name in $reached; do
      case $ci_only_targets in
      *" $name "*) echo "bin/test: leaves $name to CI for source changes. bin/test --all runs it." >&2 ;;
      *) whole_targets+="$name " ;;
      esac
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
      done < <(grep -rlE --include='*.swift' '#filePath|Instance\.root' "$dir" 2>/dev/null |
        tr '\n' '\0' | xargs -0 grep -lE '["/]Sources([/"]|$)' 2>/dev/null | sort)
    done <<<"$graph"
  fi

  for name in $tests; do
    case $whole_targets in *" $name "*) ;; *) missing=1 ;; esac
  done
  if [ -z "$missing" ]; then
    echo all
    return
  fi
  {
    for name in $whole_targets; do echo "target $name"; done
    for line in ${suites[@]+"${suites[@]}"}; do
      read -r _ name _ <<<"$line"
      case $whole_targets in *" $name "*) ;; *) echo "$line" ;; esac
    done
  } | sort -u
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
  local target=$1 dir=$2 file=$3 count decls suites files others names used
  whole() {
    echo "bin/test: $file: $1, so all of $target runs" >&2
    echo "target $target"
  }
  [ -f "$file" ] || { whole "it was deleted"; return; }
  count=$(grep -c '@Test' "$file" || true)
  [ "$count" -gt 0 ] || { whole "it declares no tests"; return; }
  grep -q '^@Test' "$file" && { whole "it declares a test outside a type"; return; }
  # Prints "<kind> <name> <private>" for each top-level declaration. A line
  # that starts in column 0 with a letter or an attribute is top level. Prints
  # "unreadable" for a `#if`, which can hide an indented declaration, and for
  # a top-level line with no name to read, such as `extension [K: V]`.
  decls=$(awk '
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
    }' "$file")
  if grep -qx unreadable <<<"$decls"; then
    whole "it has a top-level line that the selector cannot read"
    return
  fi
  suites=$(awk '$1 ~ /^(struct|class|enum|actor|extension)$/ { print $2 }' <<<"$decls" | sort -u | tr '\n' ' ')
  [ -n "$suites" ] || { whole "it declares no type"; return; }

  files=$(find "$dir" -name '*.swift' | sort)
  others=$(grep -vxF -- "$file" <<<"$files" || true)
  # The listing shows tests that other files add to these suites through
  # extensions, so count them too. A block ends only at a `}` in column 0. An
  # indented extension therefore counts to the end of its file, and the larger
  # count can only widen the selection.
  if [ -n "$others" ]; then
    local alt=${suites% }
    count=$((count + $(tr '\n' '\0' <<<"$others" |
      xargs -0 awk -v re="(^|[^A-Za-z0-9_])extension[ ]+([A-Za-z_][A-Za-z0-9_]*[.])?(${alt// /|})([^A-Za-z0-9_]|$)" '
        FNR == 1 { inside = 0 }
        $0 ~ re { inside = 1 }
        inside && /@Test/ { n++ }
        /^}/ { inside = 0 }
        END { print n + 0 }' |
      awk '{ s += $1 } END { print s + 0 }')))
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
    echo "bin/test: $file: runs ${suites% }" >&2
    echo "suites $target $count ${suites% }"
    ;;
  esac
}

# test_filters
# Reads select_tests lines on stdin and prints one --filter pattern for each.
# A file's suites become a pattern only when list_tests shows that it matches
# at least as many tests as the file and other files' extensions of its suites
# declare. Otherwise they become their whole target, so a declaration that the
# parse missed still runs.
test_filters() {
  local kind target count names pattern list= matched
  while read -r kind target count names; do
    case $kind in
    target) echo "^$target\\." ;;
    suites)
      [ -n "$list" ] || list=$(list_tests) || true
      pattern="^$target\\.(${names// /|})/"
      matched=$(grep -c -E "$pattern" <<<"$list" || true)
      if [ "$matched" -ge "$count" ]; then
        echo "$pattern"
      else
        echo "bin/test: $pattern matches $matched tests, fewer than the $count its suites declare, so all of $target runs" >&2
        echo "^$target\\."
      fi
      ;;
    esac
  done | sort -u
}
