#!/usr/bin/env bash
# Detect WordPress plugin or theme project metadata.
# Expects WORK_DIR (project root). Optional overrides: PROJECT_TYPE, SLUG, MAIN_FILE.
set -euo pipefail

WORK_DIR="${WORK_DIR:-$(pwd)}"

find_plugin_main() {
  local f
  while IFS= read -r -d '' f; do
    if head -n 40 "${f}" | grep -qE '^[ *]*Plugin Name:'; then
      echo "${f}"
      return 0
    fi
  done < <(find "${WORK_DIR}" -maxdepth 2 -type f -name '*.php' \
    ! -path '*/.git/*' ! -path '*/vendor/*' ! -path '*/node_modules/*' \
    ! -path '*/.wp-release/*' ! -path '*/dist/*' -print0 | sort -z)
  return 1
}

detect_project() {
  local style="${WORK_DIR}/style.css"
  local main="" slug="" ptype="" version="" name="Project"

  if [[ -n "${PROJECT_TYPE:-}" && "${PROJECT_TYPE}" != "auto" ]]; then
    ptype="${PROJECT_TYPE}"
  elif [[ -f "${style}" ]] && head -n 40 "${style}" | grep -qE '^[ *]*Theme Name:'; then
    ptype="theme"
  else
    ptype="plugin"
  fi

  if [[ "${ptype}" == "theme" ]]; then
    main="${style}"
    name="$(grep -E '^[ *]*Theme Name:' "${style}" | head -1 | sed -E 's/.*Theme Name:[[:space:]]*//' || true)"
    version="$(grep -E '^[ *]*Version:' "${style}" | head -1 | sed -E 's/.*Version:[[:space:]]*//' || true)"
    slug="${SLUG:-$(basename "${WORK_DIR}")}"
  else
    if [[ -n "${MAIN_FILE:-}" ]]; then
      if [[ "${MAIN_FILE}" = /* ]]; then
        main="${MAIN_FILE}"
      else
        main="${WORK_DIR}/${MAIN_FILE}"
      fi
    else
      main="$(find_plugin_main || true)"
    fi
    if [[ -z "${main}" || ! -f "${main}" ]]; then
      echo "error: could not find plugin main file with a Plugin Name header" >&2
      return 1
    fi
    name="$(grep -E '^[ *]*Plugin Name:' "${main}" | head -1 | sed -E 's/.*Plugin Name:[[:space:]]*//' || true)"
    version="$(grep -E '^[ *]*Version:' "${main}" | head -1 | sed -E 's/.*Version:[[:space:]]*//' || true)"
    slug="${SLUG:-$(basename "${main}" .php)}"
  fi

  DETECTED_TYPE="${ptype}"
  DETECTED_MAIN="${main}"
  DETECTED_SLUG="${slug}"
  DETECTED_VERSION="$(echo "${version:-}" | tr -d '[:space:]')"
  DETECTED_NAME="${name:-Project}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  detect_project
  echo "type=${DETECTED_TYPE}"
  echo "main=${DETECTED_MAIN}"
  echo "slug=${DETECTED_SLUG}"
  echo "version=${DETECTED_VERSION}"
  echo "name=${DETECTED_NAME}"
fi
