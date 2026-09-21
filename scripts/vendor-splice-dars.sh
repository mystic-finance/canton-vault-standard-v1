#!/usr/bin/env bash
# Rebuilds dependencies/*.dar from the Splice token-standard sources at SPLICE_TAG.
set -euo pipefail

SPLICE_TAG="${SPLICE_TAG:-0.8.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dependencies"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet --no-checkout --depth 1 --branch "$SPLICE_TAG" --filter=blob:none --sparse \
  https://github.com/canton-network/splice.git "$WORK/splice"
git -C "$WORK/splice" sparse-checkout set token-standard >/dev/null
git -C "$WORK/splice" checkout --quiet "$SPLICE_TAG"
TS="$WORK/splice/token-standard"

# Dependency order matters: each package's data-dependencies point at earlier ones.
PACKAGES=(
  splice-api-token-metadata-v1
  splice-api-token-holding-v1
  splice-api-token-holding-v2
  splice-api-token-transfer-events-v2
  splice-api-token-transfer-instruction-v1
  splice-api-token-transfer-instruction-v2
  splice-api-token-allocation-v1
  splice-api-token-allocation-v2
  splice-api-token-allocation-instruction-v1
  splice-api-token-allocation-instruction-v2
  splice-api-token-allocation-request-v1
  splice-api-token-allocation-request-v2
  splice-token-standard-utils
)

mkdir -p "$OUT"
for p in "${PACKAGES[@]}"; do
  echo "building $p"
  (cd "$TS/$p" && dpm build >/dev/null 2>&1)
  version="$(grep '^version:' "$TS/$p/daml.yaml" | awk '{print $2}')"
  # Splice manifests reference sibling DARs as <name>-current.dar.
  cp "$TS/$p/.daml/dist/$p-$version.dar" "$TS/$p/.daml/dist/$p-current.dar"
  cp "$TS/$p/.daml/dist/$p-$version.dar" "$OUT/$p-$version.dar"
done

cat > "$OUT/VERSIONS.md" <<MD
# Vendored Splice DARs

Built from [canton-network/splice](https://github.com/canton-network/splice) tag \`$SPLICE_TAG\`
with SDK $(dpm version --active 2>/dev/null || echo '?') by \`scripts/vendor-splice-dars.sh\`.
Regenerate with \`SPLICE_TAG=<tag> scripts/vendor-splice-dars.sh\`; don't edit the DARs by hand.

| DAR | Splice package version |
| --- | --- |
MD
for p in "${PACKAGES[@]}"; do
  version="$(grep '^version:' "$TS/$p/daml.yaml" | awk '{print $2}')"
  echo "| \`$p-$version.dar\` | $version |" >> "$OUT/VERSIONS.md"
done
echo "done: $OUT"
