#!/bin/sh
set -eu
version="${ELASTIC_VERSION:-9.5.6}"
commit="${ELASTIC_COMMIT:-fd1e8011342a0988e432b999cea4bf884ca120ed}"
image="${IMAGE:-mohankrishna999/elasticsearch:${version}-patched}"
platforms="${PLATFORMS:-linux/amd64}"
output="${OUTPUT:---load}"
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v${version}" \
  https://github.com/elastic/elasticsearch.git "$workspace/source"
test "$(git -C "$workspace/source" rev-parse HEAD)" = "$commit"
(
  cd "$workspace/source"
  ./gradlew --no-daemon -Dbuild.snapshot=false \
    :distribution:archives:linux-tar:assemble \
    :distribution:archives:linux-aarch64-tar:assemble
)
dist="$workspace/source/distribution/archives"
# shellcheck disable=SC2086
docker buildx build --platform "$platforms" --build-context "dist=$dist" \
  --build-arg ELASTIC_VERSION="$version" --tag "$image" $output "$root"
