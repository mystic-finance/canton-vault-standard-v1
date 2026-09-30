#!/usr/bin/env bash
# Copies dependencies/*.dar from the Splice release bundle at SPLICE_VERSION.
# Released DARs, not DARs built from source: only these carry the package ids
# the network runs, and interfaces are identified by package id.
set -euo pipefail

SPLICE_VERSION="${SPLICE_VERSION:-0.8.4}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dependencies"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Reuse a downloaded bundle if SPLICE_BUNDLE points at one; it is 800 MB.
BUNDLE="${SPLICE_BUNDLE:-$WORK/splice-node.tar.gz}"
if [ ! -f "$BUNDLE" ]; then
  curl -sSL --http1.1 --retry 5 -C - -o "$BUNDLE" \
    "https://github.com/digital-asset/decentralized-canton-sync/releases/download/v$SPLICE_VERSION/${SPLICE_VERSION}_splice-node.tar.gz"
fi

DARS=(
  splice-api-token-metadata-v1-1.0.0
  splice-api-token-holding-v1-1.0.0
  splice-api-token-holding-v2-1.0.0
  splice-api-token-transfer-events-v2-1.0.0
  splice-api-token-transfer-instruction-v1-1.0.0
  splice-api-token-transfer-instruction-v2-1.0.0
  splice-api-token-allocation-v1-1.0.0
  splice-api-token-allocation-v2-1.0.0
  splice-api-token-allocation-instruction-v1-1.0.0
  splice-api-token-allocation-instruction-v2-1.0.0
  splice-api-token-allocation-request-v1-1.0.0
  splice-api-token-allocation-request-v2-1.0.0
  splice-token-standard-utils-2.0.0
  splice-test-token-v2-1.0.1
)

tar -xzf "$BUNDLE" -C "$WORK" $(printf 'splice-node/dars/%s.dar ' "${DARS[@]}")
mkdir -p "$OUT"
rm -f "$OUT"/*.dar
for d in "${DARS[@]}"; do
  cp "$WORK/splice-node/dars/$d.dar" "$OUT/$d.dar"
done

cat > "$OUT/VERSIONS.md" <<MD
# Vendored Splice DARs

Copied from the Splice release bundle \`${SPLICE_VERSION}_splice-node.tar.gz\` by
\`scripts/vendor-splice-dars.sh\`. These are the released DARs, so their package ids
match the network's; DARs built from the same source do not.
Regenerate with \`SPLICE_VERSION=<version> scripts/vendor-splice-dars.sh\`; don't edit
the DARs by hand.

These DARs are Splice's, licensed under Apache 2.0, copyright Digital Asset
(Switzerland) GmbH and its affiliates: see the Splice repository. The MIT license
at the root of this repository does not apply to them.

| DAR |
| --- |
MD
for d in "${DARS[@]}"; do
  echo "| \`$d.dar\` |" >> "$OUT/VERSIONS.md"
done
echo "done: $OUT"
