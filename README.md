# wp-release

Reusable GitHub Actions tooling that releases **WordPress plugins and themes** for the `sometechwork` org.

Each project only needs a thin workflow. Version bumps, changelog updates, WordPress ZIP packaging, tags, and GitHub Releases live here.

## Add to a plugin or theme repo

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    branches: [main]

permissions:
  contents: write
  models: read

jobs:
  release:
    uses: sometechwork/wp-release/.github/workflows/wordpress-release.yml@v1
    secrets: inherit
```

### Optional inputs

```yaml
jobs:
  release:
    uses: sometechwork/wp-release/.github/workflows/wordpress-release.yml@v1
    secrets: inherit
    with:
      branch: main
      project_type: auto          # auto | plugin | theme
      slug: my-plugin             # ZIP root folder (defaults to main PHP basename / theme dir)
      main_file: my-plugin.php    # plugin only, if auto-detect fails
```

## What it does

1. Collects commits since the last version tag.
2. Chooses **major / minor / patch**:
   - Conventional Commits when most messages match (`feat:` → minor, `fix:` → patch, `BREAKING CHANGE` / `type!:` → major).
   - Otherwise **GitHub Models** AI classification.
   - If Models is unavailable → **patch** + raw commit subjects.
3. Updates `Version` in the plugin header or theme `style.css`, bumps matching `*_VERSION` PHP defines, and prepends `CHANGELOG.md`.
4. Commits `chore(release): vX.Y.Z`, tags, pushes.
5. Builds `slug-X.Y.Z.zip` with root folder **`slug/`** (so WordPress overwrites instead of installing a duplicate).
6. Publishes a GitHub Release with the ZIP attached.

Release commits themselves are skipped (`chore(release):`).

## Repo settings (each consumer)

**Settings → Actions → General → Workflow permissions** → **Read and write permissions**.

For AI fallback, GitHub Models must be allowed for the org (`models: read` is already on the reusable workflow).

## How scripts are loaded

Caller repos must not `git clone` this private repo with `GITHUB_TOKEN` (it only has access to the caller). Scripts run via **composite actions** under `actions/`, which GitHub fetches when the reusable workflow references `sometechwork/wp-release/actions/...@v1`.

## Local scripts

From a plugin/theme checkout:

```bash
git clone --depth 1 --branch v1 https://github.com/sometechwork/wp-release.git .wp-release
WORK_DIR=$PWD .wp-release/scripts/prepare-release.sh   # dry logic; commits are done by Actions
WORK_DIR=$PWD .wp-release/scripts/build-wp-zip.sh
```

## ZIP root folder tip

Always ship ZIPs whose top-level folder matches the live `wp-content/plugins/...` or `themes/...` directory name. This tooling defaults plugin slug to the main file basename (e.g. `stw-wolves-plugin.php` → `stw-wolves-plugin`).
