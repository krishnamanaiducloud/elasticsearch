#!/bin/bash
# Replace vulnerable third-party jars in an unpacked Elasticsearch distribution with pinned Maven Central releases.
# Usage: patch-jars.sh <es-home> <manifest>
#
# Manifest operations (one per line, '#' comments):
#   jar     <old-file-name>          <group:artifact:version> <sha256>   replace every copy of a jar
#   add     <dir-relative-to-home>   <group:artifact:version> <sha256>   add a jar to a module directory
#   impl    <container-jar-name>     <IMPL-JARS/<sub>/<old>.jar> <group:artifact:version> <sha256>
#                                                                         swap an exploded embedded jar and its LISTING.TXT entry
#   unshade <uber-jar-name>          <entry-prefix>                       drop shaded entries from an uber jar
#   shade   <uber-jar-name>          <group:artifact:version> <sha256>   merge a jar's entries into an uber jar
# Every operation must match at least one file or entry, so a stale manifest fails the build.
set -euo pipefail

home=$1
manifest=$2
cache=${JAR_CACHE:-/tmp/jar-cache}
mkdir -p "$cache"

fetch() { # coordinate sha256 -> path
  local g a v f url
  IFS=: read -r g a v <<<"$1"
  f="$cache/$a-$v.jar"
  if [ ! -s "$f" ]; then
    url="https://repo1.maven.org/maven2/${g//.//}/$a/$v/$a-$v.jar"
    curl -fsSL --retry 8 --retry-all-errors --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o "$f.part" "$url"
    mv "$f.part" "$f"
  fi
  echo "$2  $f" | sha256sum -c --quiet - >&2 || { rm -f "$f"; echo "checksum mismatch for $1" >&2; return 1; }
  echo "$f"
}

jarname() { # coordinate -> artifact-version.jar
  local g a v
  IFS=: read -r g a v <<<"$1"
  echo "$a-$v.jar"
}

find_named() { find "$home" -type f -name "$1"; }

rezip() { # workdir jar
  local w=$1 out=$2
  rm -f "$out.new"
  (cd "$w" && find . -exec touch -h -d '1980-01-01T00:00:00Z' {} + \
    && zip -q -X "$out.new" META-INF/MANIFEST.MF \
    && zip -q -X -r "$out.new" . -x META-INF/MANIFEST.MF)
  mv "$out.new" "$out"
}

exec </dev/null
while read -r -u 3 op a1 a2 a3 a4; do
  case "$op" in ''|'#'*) continue ;; esac
  case "$op" in
    jar)
      new=$(fetch "$a2" "$a3")
      hits=$(find_named "$a1")
      [ -n "$hits" ] || { echo "jar: no file named $a1" >&2; exit 1; }
      for f in $hits; do
        cp "$new" "$(dirname "$f")/$(jarname "$a2")"
        rm -f "$f"
        echo "jar     ${f#"$home"/} -> $(jarname "$a2")"
      done
      ;;
    add)
      new=$(fetch "$a2" "$a3")
      [ -d "$home/$a1" ] || { echo "add: no directory $a1" >&2; exit 1; }
      cp "$new" "$home/$a1/$(jarname "$a2")"
      echo "add     $a1/$(jarname "$a2")"
      ;;
    impl)
      new=$(fetch "$a3" "$a4")
      hits=$(find_named "$a1")
      [ -n "$hits" ] || { echo "impl: no container named $a1" >&2; exit 1; }
      for f in $hits; do
        w=$(mktemp -d)
        (cd "$w" && unzip -q "$f")
        sub=$(dirname "$a2")
        old=$(basename "$a2")
        [ -d "$w/$a2" ] || { echo "impl: $a2 not in ${f#"$home"/}" >&2; exit 1; }
        rm -rf "${w:?}/$a2"
        mkdir -p "$w/$sub/$(jarname "$a3")"
        (cd "$w/$sub/$(jarname "$a3")" && unzip -q "$new")
        grep -qx "$old" "$w/$sub/LISTING.TXT" || { echo "impl: $old not listed in $sub/LISTING.TXT" >&2; exit 1; }
        sed -i "s|^$old\$|$(jarname "$a3")|" "$w/$sub/LISTING.TXT"
        rezip "$w" "$f"
        rm -rf "$w"
        echo "impl    ${f#"$home"/}: $old -> $(jarname "$a3")"
      done
      ;;
    unshade)
      hits=$(find_named "$a1")
      [ -n "$hits" ] || { echo "unshade: no jar named $a1" >&2; exit 1; }
      for f in $hits; do
        n=$(unzip -Z1 "$f" | grep -c "^$a2" || true)
        [ "$n" -gt 0 ] || { echo "unshade: no $a2 entries in ${f#"$home"/}" >&2; exit 1; }
        zip -q -d "$f" "$a2*" >/dev/null
        echo "unshade ${f#"$home"/}: removed $n entries under $a2"
      done
      ;;
    shade)
      new=$(fetch "$a2" "$a3")
      hits=$(find_named "$a1")
      [ -n "$hits" ] || { echo "shade: no jar named $a1" >&2; exit 1; }
      for f in $hits; do
        w=$(mktemp -d)
        n=$(mktemp -d)
        (cd "$w" && unzip -q "$f")
        (cd "$n" && unzip -q "$new" -x 'META-INF/MANIFEST.MF' 'module-info.class' 'META-INF/versions/*/module-info.class' \
               'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/*.DSA' 'META-INF/INDEX.LIST')
        # service registrations already merged into the uber jar are combined, not overwritten
        if [ -d "$n/META-INF/services" ]; then
          find "$n/META-INF/services" -type f | while read -r s; do
            rel=${s#"$n"/}
            if [ -f "$w/$rel" ]; then
              cat "$w/$rel" "$s" | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++' > "$w/$rel.merged"
              mv "$w/$rel.merged" "$w/$rel"
              rm -f "$s"
            fi
          done
        fi
        cp -a "$n/." "$w/"
        rezip "$w" "$f"
        rm -rf "$w" "$n"
        echo "shade   ${f#"$home"/}: + $(jarname "$a2")"
      done
      ;;
    *) echo "unknown operation: $op" >&2; exit 1 ;;
  esac
done 3< "$manifest"
