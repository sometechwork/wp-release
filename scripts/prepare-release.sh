#!/usr/bin/env bash
# Decide bump, update version headers + CHANGELOG for a WordPress plugin or theme.
# Env:
#   WORK_DIR       Project root (default: cwd)
#   PROJECT_TYPE   auto|plugin|theme
#   SLUG           ZIP / folder slug override
#   MAIN_FILE      Relative path to main plugin PHP (plugins only)
#   GITHUB_TOKEN   Optional; enables GitHub Models AI fallback
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/detect-project.sh
source "${SCRIPT_DIR}/lib/detect-project.sh"

WORK_DIR="${WORK_DIR:-$(pwd)}"
CHANGELOG_FILE="${WORK_DIR}/CHANGELOG.md"
CONV_RE='^(feat|feature|fix|chore|docs|style|refactor|perf|test|build|ci|revert)(\([^)]+\))?!?:'
BREAKING_TYPE_RE='^[a-zA-Z]+(\([^)]+\))?!:'

normalize_version() {
  local v="$1"
  v="${v#v}"
  echo "${v}"
}

semver_bump() {
  local version bump major minor patch
  version="$(normalize_version "$1")"
  bump="$2"
  IFS=. read -r major minor patch <<EOF
${version}
EOF
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"
  case "${bump}" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
    *) echo "error: invalid bump '${bump}'" >&2; exit 1 ;;
  esac
  echo "${major}.${minor}.${patch}"
}

write_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$1" >> "${GITHUB_OUTPUT}"
  fi
}

detect_project

CURRENT_VERSION="$(normalize_version "${DETECTED_VERSION}")"
LAST_TAG="$(git -C "${WORK_DIR}" describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -z "${LAST_TAG}" ]]; then
  RANGE=""
else
  RANGE="${LAST_TAG}..HEAD"
fi

if [[ -z "${CURRENT_VERSION}" ]]; then
  if [[ -n "${LAST_TAG}" ]]; then
    CURRENT_VERSION="$(normalize_version "${LAST_TAG}")"
  else
    CURRENT_VERSION="0.0.0"
  fi
fi

COMMITS_FILE="$(mktemp)"
ADDED_FILE="$(mktemp)"
CHANGED_FILE="$(mktemp)"
FIXED_FILE="$(mktemp)"
SECTION_FILE="$(mktemp)"
cleanup() {
  rm -f "${COMMITS_FILE}" "${ADDED_FILE}" "${CHANGED_FILE}" "${FIXED_FILE}" "${SECTION_FILE}" "${HEADER_FILE:-}" "${REST_FILE:-}"
}
trap cleanup EXIT

if [[ -n "${RANGE}" ]]; then
  git -C "${WORK_DIR}" log --pretty=format:'%s' "${RANGE}" | sed '/^$/d' > "${COMMITS_FILE}"
  COMMIT_BODIES="$(git -C "${WORK_DIR}" log --pretty=format:'%s%n%b%n---' "${RANGE}")"
  DIFFSTAT="$(git -C "${WORK_DIR}" diff --stat "${LAST_TAG}"..HEAD 2>/dev/null | tail -n 20 || true)"
else
  git -C "${WORK_DIR}" log --pretty=format:'%s' | sed '/^$/d' | head -50 > "${COMMITS_FILE}"
  COMMIT_BODIES="$(git -C "${WORK_DIR}" log --pretty=format:'%s%n%b%n---' | head -200)"
  DIFFSTAT="$(git -C "${WORK_DIR}" diff --stat HEAD~20..HEAD 2>/dev/null | tail -n 20 || true)"
fi

FILTERED_FILE="$(mktemp)"
grep -v '^chore(release):' "${COMMITS_FILE}" > "${FILTERED_FILE}" || true
mv "${FILTERED_FILE}" "${COMMITS_FILE}"

if [[ ! -s "${COMMITS_FILE}" ]]; then
  echo "No releasable commits since last tag; skipping."
  write_output "skip=true"
  exit 0
fi

TOTAL="$(wc -l < "${COMMITS_FILE}" | tr -d ' ')"
CONV_COUNT=0
while IFS= read -r c || [[ -n "${c}" ]]; do
  if [[ "${c}" =~ $CONV_RE ]]; then
    CONV_COUNT=$((CONV_COUNT + 1))
  fi
done < "${COMMITS_FILE}"

USE_CONVENTIONAL=false
if (( CONV_COUNT * 2 >= TOTAL )); then
  USE_CONVENTIONAL=true
fi

BUMP="patch"
: > "${ADDED_FILE}"
: > "${CHANGED_FILE}"
: > "${FIXED_FILE}"

classify_conventional() {
  local subject="$1" type body_hint
  if [[ ! "${subject}" =~ $CONV_RE ]]; then
    echo "${subject}" >> "${CHANGED_FILE}"
    return
  fi
  type="$(printf '%s' "${subject}" | sed -E 's/^([a-zA-Z]+)(\([^)]+\))?!?:.*/\1/')"
  body_hint="$(printf '%s' "${subject}" | sed -E 's/^[a-zA-Z]+(\([^)]+\))?!?:[[:space:]]*//')"
  case "${type}" in
    feat|feature) echo "${body_hint}" >> "${ADDED_FILE}" ;;
    fix) echo "${body_hint}" >> "${FIXED_FILE}" ;;
    *) echo "${body_hint}" >> "${CHANGED_FILE}" ;;
  esac
}

decide_bump_conventional() {
  local subject bump="patch" type
  while IFS= read -r subject || [[ -n "${subject}" ]]; do
    if [[ "${subject}" =~ $BREAKING_TYPE_RE ]]; then
      echo "major"
      return
    fi
  done < "${COMMITS_FILE}"
  if printf '%s' "${COMMIT_BODIES}" | grep -q 'BREAKING CHANGE'; then
    echo "major"
    return
  fi
  while IFS= read -r subject || [[ -n "${subject}" ]]; do
    if [[ "${subject}" =~ $CONV_RE ]]; then
      type="$(printf '%s' "${subject}" | sed -E 's/^([a-zA-Z]+)(\([^)]+\))?!?:.*/\1/')"
      if [[ "${type}" == "feat" || "${type}" == "feature" ]]; then
        bump="minor"
      fi
    fi
  done < "${COMMITS_FILE}"
  echo "${bump}"
}

call_github_models() {
  local token="${GITHUB_TOKEN:-}"
  if [[ -z "${token}" ]] || ! command -v jq >/dev/null 2>&1; then
    return 1
  fi

  local commits_text system_prompt user_prompt payload response content bump_json
  commits_text="$(sed 's/^/- /' "${COMMITS_FILE}")"
  system_prompt='You classify software release bumps for a WordPress plugin or theme. Reply with ONLY valid JSON (no markdown): {"bump":"major"|"minor"|"patch","changelog":["user-facing bullet",...]}. Rules: breaking behavior or incompatible API/UI changes => major; new user-facing capability => minor; bugfixes, styling, docs, chores, refactors => patch. Changelog bullets must be concise, past-tense or noun phrases, no commit hashes.'
  user_prompt="Project: ${DETECTED_NAME} (${DETECTED_TYPE})
Commits since last release:
${commits_text}

Diffstat:
${DIFFSTAT}

Optional bodies:
${COMMIT_BODIES}"

  payload="$(jq -n \
    --arg model "openai/gpt-4o" \
    --arg sys "${system_prompt}" \
    --arg user "${user_prompt}" \
    '{model:$model,temperature:0,messages:[{role:"system",content:$sys},{role:"user",content:$user}]}')"

  response="$(curl -sS -X POST "https://models.github.ai/inference/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -d "${payload}" || true)"

  content="$(printf '%s' "${response}" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)"
  [[ -n "${content}" ]] || { echo "GitHub Models failed: ${response}" >&2; return 1; }
  content="$(printf '%s' "${content}" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')"
  bump_json="$(printf '%s' "${content}" | jq -r '.bump // empty' 2>/dev/null || true)"
  [[ "${bump_json}" =~ ^(major|minor|patch)$ ]] || { echo "Invalid AI bump: ${content}" >&2; return 1; }

  BUMP="${bump_json}"
  : > "${ADDED_FILE}"
  : > "${FIXED_FILE}"
  : > "${CHANGED_FILE}"
  printf '%s' "${content}" | jq -r '.changelog[]? // empty' >> "${CHANGED_FILE}"
  echo "AI decided bump=${BUMP}"
}

SOURCE="conventional"
if [[ "${USE_CONVENTIONAL}" == "true" ]]; then
  BUMP="$(decide_bump_conventional)"
  while IFS= read -r c || [[ -n "${c}" ]]; do
    classify_conventional "${c}"
  done < "${COMMITS_FILE}"
  SOURCE="conventional"
else
  if call_github_models; then
    SOURCE="ai"
  else
    echo "AI unavailable; defaulting to patch + raw commit subjects." >&2
    BUMP="patch"
    SOURCE="fallback"
    : > "${ADDED_FILE}"
    : > "${FIXED_FILE}"
    cp "${COMMITS_FILE}" "${CHANGED_FILE}"
  fi
fi

NEW_VERSION="$(semver_bump "${CURRENT_VERSION}" "${BUMP}")"
TODAY="$(date -u +%Y-%m-%d)"

{
  echo "## ${NEW_VERSION} - ${TODAY}"
  echo
  if [[ -s "${ADDED_FILE}" ]]; then echo "### Added"; sed 's/^/- /' "${ADDED_FILE}"; echo; fi
  if [[ -s "${CHANGED_FILE}" ]]; then echo "### Changed"; sed 's/^/- /' "${CHANGED_FILE}"; echo; fi
  if [[ -s "${FIXED_FILE}" ]]; then echo "### Fixed"; sed 's/^/- /' "${FIXED_FILE}"; echo; fi
  if [[ ! -s "${ADDED_FILE}" && ! -s "${CHANGED_FILE}" && ! -s "${FIXED_FILE}" ]]; then
    echo "### Changed"
    echo "- Maintenance release"
    echo
  fi
} > "${SECTION_FILE}"

if [[ -f "${CHANGELOG_FILE}" ]]; then
  HEADER_FILE="$(mktemp)"
  REST_FILE="$(mktemp)"
  awk 'BEGIN{p=1} /^## /{exit} {print}' "${CHANGELOG_FILE}" > "${HEADER_FILE}"
  awk 'BEGIN{p=0} /^## /{p=1} p{print}' "${CHANGELOG_FILE}" > "${REST_FILE}"
  {
    cat "${HEADER_FILE}"
    if [[ -s "${HEADER_FILE}" ]] && [[ "$(tail -c1 "${HEADER_FILE}" | wc -l)" -eq 0 ]]; then echo; fi
    cat "${SECTION_FILE}"
    cat "${REST_FILE}"
  } > "${CHANGELOG_FILE}.tmp"
  mv "${CHANGELOG_FILE}.tmp" "${CHANGELOG_FILE}"
else
  {
    echo "# Changelog"
    echo
    echo "All notable changes to ${DETECTED_NAME} are documented in this file."
    echo
    cat "${SECTION_FILE}"
  } > "${CHANGELOG_FILE}"
fi

# Bump Version header in main file.
sed -i.bak -E "s/^([[:space:]]*\*?[[:space:]]*Version:).*/\1 ${NEW_VERSION}/" "${DETECTED_MAIN}"

# Bump PHP constants whose value equals the previous version (plugins).
if [[ "${DETECTED_TYPE}" == "plugin" ]]; then
  while IFS= read -r -d '' php; do
    sed -i.bak -E "s/(define\(\s*'[^']*VERSION'\s*,\s*')${CURRENT_VERSION}('\s*\))/\1${NEW_VERSION}\2/g" "${php}"
    sed -i.bak -E "s/(define\(\s*\"[^\"]*VERSION\"\s*,\s*\")${CURRENT_VERSION}(\"\s*\))/\1${NEW_VERSION}\2/g" "${php}"
    rm -f "${php}.bak"
  done < <(find "${WORK_DIR}" -maxdepth 3 -type f -name '*.php' \
    ! -path '*/.git/*' ! -path '*/vendor/*' ! -path '*/node_modules/*' \
    ! -path '*/.wp-release/*' ! -path '*/dist/*' -print0)
fi
rm -f "${DETECTED_MAIN}.bak"

NOTES_FILE="${WORK_DIR}/dist/release-notes.md"
mkdir -p "${WORK_DIR}/dist"
cp "${SECTION_FILE}" "${NOTES_FILE}"

# Paths to commit (relative to WORK_DIR).
MAIN_REL="${DETECTED_MAIN#"${WORK_DIR}"/}"
COMMIT_PATHS="${MAIN_REL}"$'\n'"CHANGELOG.md"

echo "Release prepare complete:"
echo "  project=${DETECTED_NAME} (${DETECTED_TYPE})"
echo "  slug=${DETECTED_SLUG}"
echo "  main=${MAIN_REL}"
echo "  current=${CURRENT_VERSION}"
echo "  bump=${BUMP} (source=${SOURCE})"
echo "  new=${NEW_VERSION}"

write_output "skip=false"
write_output "bump=${BUMP}"
write_output "source=${SOURCE}"
write_output "project_type=${DETECTED_TYPE}"
write_output "slug=${DETECTED_SLUG}"
write_output "main_file=${MAIN_REL}"
write_output "current_version=${CURRENT_VERSION}"
write_output "new_version=${NEW_VERSION}"
write_output "tag=v${NEW_VERSION}"
write_output "notes_file=${NOTES_FILE}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "commit_paths<<EOF"
    printf '%s\n' "${COMMIT_PATHS}"
    git -C "${WORK_DIR}" diff --name-only -- '*.php' 'style.css' 'CHANGELOG.md' 2>/dev/null || true
    echo "EOF"
  } >> "${GITHUB_OUTPUT}"
fi
