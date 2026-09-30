#!/bin/bash
set -euo pipefail

if (( $# != 1 )); then
    echo "Usage: $0 <postgres-service>" >&2
    exit 64
fi

readonly SERVICE="$1"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SNAPSHOT_DIR="${SCRIPT_DIR}/snapshots"
readonly TIMESTAMP="$(date '+%Y-%m-%d_%H%M%S')"
readonly OUTPUT="${SNAPSHOT_DIR}/${SERVICE}-${TIMESTAMP}.dump"
readonly TEMP="${OUTPUT}.partial"

mkdir -p "${SNAPSHOT_DIR}"

cleanup() {
    rm -f "${TEMP}"
}
trap cleanup EXIT

echo "Creating PostgreSQL snapshot"
echo "  service: ${SERVICE}"
echo "  output:  ${OUTPUT}"
echo

SECONDS=0

pg_dump \
    --format=custom \
    --file="${TEMP}" \
    "service=${SERVICE}"

mv "${TEMP}" "${OUTPUT}"

ELAPSED="${SECONDS}"
HOURS=$((ELAPSED / 3600))
MINUTES=$(((ELAPSED % 3600) / 60))
SECONDS_LEFT=$((ELAPSED % 60))

echo
echo "Snapshot completed"
printf '  duration: %02d:%02d:%02d\n' \
    "${HOURS}" "${MINUTES}" "${SECONDS_LEFT}"
echo "  file:     ${OUTPUT}"
echo "  size:     $(du -h "${OUTPUT}" | cut -f1)"
