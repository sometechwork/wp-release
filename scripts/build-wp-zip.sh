#!/usr/bin/env bash
# Build a WordPress-ready ZIP with the correct root folder slug.
# Env: WORK_DIR, PROJECT_TYPE, SLUG, MAIN_FILE (same as prepare-release.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/detect-project.sh
source "${SCRIPT_DIR}/lib/detect-project.sh"

WORK_DIR="${WORK_DIR:-$(pwd)}"
detect_project

SLUG="${DETECTED_SLUG}"
VERSION="${DETECTED_VERSION}"
if [[ -z "${VERSION}" ]]; then
  echo "error: could not read version from ${DETECTED_MAIN}" >&2
  exit 1
fi

OUT_DIR="${WORK_DIR}/dist"
ZIP_NAME="${SLUG}-${VERSION}.zip"
ZIP_PATH="${OUT_DIR}/${ZIP_NAME}"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${OUT_DIR}" "${STAGE}/${SLUG}"
rm -f "${ZIP_PATH}"

rsync -a \
  --exclude='.git/' \
  --exclude='.github/' \
  --exclude='.wp-release/' \
  --exclude='scripts/' \
  --exclude='dist/' \
  --exclude='node_modules/' \
  --exclude='vendor/' \
  --exclude='*.zip' \
  --exclude='.DS_Store' \
  --exclude='.gitignore' \
  --exclude='.gitattributes' \
  "${WORK_DIR}/" "${STAGE}/${SLUG}/"

(
  cd "${STAGE}"
  zip -rq "${ZIP_PATH}" "${SLUG}" -x '*.DS_Store'
)

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "zip_path=${ZIP_PATH}"
    echo "zip_name=${ZIP_NAME}"
    echo "version=${VERSION}"
    echo "slug=${SLUG}"
  } >> "${GITHUB_OUTPUT}"
fi

echo "Built ${ZIP_PATH}"
