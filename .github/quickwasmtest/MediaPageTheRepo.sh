#!/usr/bin/env bash
set -euo pipefail

tool="${1:?Usage: MediaPageTheRepo.sh <tool> [source-tag] [--publish]}"
source_tag="${2:-${SOURCE_TAG_INPUT:-}}"
mode="${3:-}"

case "$tool" in
  wordcraft) upstream="storytold/wordcraft" ;;
  gridcraft) upstream="storytold/gridcraft" ;;
  pdfcraft) upstream="storytold/pdfcraft" ;;
  deckcraft) upstream="storytold/deckcraft" ;;
  *) printf 'Unknown tool: %s\n' "$tool" >&2; exit 2 ;;
esac

if [[ "$mode" != "" && "$mode" != "--publish" ]]; then
  printf 'Unknown option: %s\n' "$mode" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir/../.." rev-parse --show-toplevel)"
patcher="$script_dir/patch-web-ui.py"
trunk_version="0.21.14"
craft_fonts_commit="3d9ab3a132ed0eff457e424226a435a901da30d3"
patch_version="discord-promotions-hidden-v3"
artifact_format="quickwasmtest-web-v1"

if [[ -z "$source_tag" ]]; then
  source_tag="$(gh api "repos/$upstream/releases/latest" --jq .tag_name)"
fi
if ! git check-ref-format "refs/tags/$source_tag"; then
  printf 'Invalid upstream release tag: %s\n' "$source_tag" >&2
  exit 2
fi

path="$HOME/.cargo/bin:$PATH"
export PATH="$path"
command -v cargo >/dev/null || { printf 'Install Rust with rustup before building.\n' >&2; exit 5; }
command -v rustup >/dev/null || { printf 'Install Rust with rustup before building.\n' >&2; exit 5; }
if ! command -v trunk >/dev/null 2>&1; then
  cargo install trunk --version "$trunk_version" --locked
fi
if ! rustup target list --installed | grep -qx wasm32-unknown-unknown; then
  rustup target add wasm32-unknown-unknown
fi

work_root="$(mktemp -d "${TMPDIR:-/tmp}/mediapager-${tool}.XXXXXX")"
output_root="${OUTPUT_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mediapager-artifacts-$tool}"
mkdir -p "$output_root"
cleanup() { rm -rf "$work_root"; }
trap cleanup EXIT

git clone --quiet --depth 1 --branch "$source_tag" "https://github.com/$upstream.git" "$work_root/source"
git clone --quiet --no-checkout https://github.com/storytold/craft-fonts.git "$work_root/craft-fonts"
git -C "$work_root/craft-fonts" fetch --quiet --depth 1 origin "$craft_fonts_commit"
git -C "$work_root/craft-fonts" checkout --quiet --detach "$craft_fonts_commit"

python3 "$patcher" "$work_root/source"
export CRAFT_FONTS_DIR="$work_root/craft-fonts"
export CRAFT_FONTS_REQUIRED=1
export CARGO_TERM_COLOR=never
if [[ -z "${CARGO_TARGET_DIR:-}" && -d "$HOME/.quickwasmtest/sources/$tool/target" ]]; then
  export CARGO_TARGET_DIR="$HOME/.quickwasmtest/sources/$tool/target"
fi
web_app="$work_root/source/apps/$tool-web"
[[ -d "$web_app" ]] || { printf 'Web app directory not found: %s\n' "$web_app" >&2; exit 3; }
(cd "$web_app" && trunk build --release)

dist="$work_root/source/dist/web"
source_commit="$(git -C "$work_root/source" rev-parse HEAD)"
archive="$output_root/$tool-web-$source_tag.mediapager.zip"
SOURCE_TAG="$source_tag" SOURCE_COMMIT="$source_commit" CRAFT_FONTS_COMMIT="$craft_fonts_commit" \
PATCH_VERSION="$patch_version" ARTIFACT_FORMAT="$artifact_format" TOOL="$tool" DIST="$dist" ARCHIVE="$archive" \
python3 - <<'PY'
import json
import os
import re
import urllib.parse
import zipfile
from pathlib import Path

dist = Path(os.environ["DIST"]).resolve()
index = dist / "index.html"
if not index.is_file():
    raise SystemExit(f"Build did not produce {index}")

references = re.findall(r'''["']((?:\./)?[^"']+\.(?:js|wasm|css))["']''', index.read_text(encoding="utf-8"), re.I)
if not references:
    raise SystemExit("Built index.html does not reference JS, WASM, or CSS assets")
for reference in references:
    asset = (dist / urllib.parse.unquote(reference.removeprefix("./"))).resolve()
    if not asset.is_relative_to(dist) or not asset.is_file():
        raise SystemExit(f"Built asset is missing or escapes the bundle: {reference}")

manifest = {
    "tool": os.environ["TOOL"],
    "sourceVersion": os.environ["SOURCE_TAG"],
    "sourceCommit": os.environ["SOURCE_COMMIT"],
    "craftFontsCommit": os.environ["CRAFT_FONTS_COMMIT"],
    "discordUiPatch": os.environ["PATCH_VERSION"],
    "artifactFormat": os.environ["ARTIFACT_FORMAT"],
}
(dist / ".quickwasmtest-build.json").write_text(json.dumps(manifest, separators=(",", ":")) + "\n", encoding="utf-8")

archive = Path(os.environ["ARCHIVE"])
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
    for path in sorted(dist.rglob("*")):
        if path.is_file():
            bundle.write(path, path.relative_to(dist).as_posix())
print(f"Validated {len(references)} referenced assets; created {archive}")
PY

if [[ "$mode" == "--publish" ]]; then
  [[ "${GITHUB_ACTIONS:-}" == "true" ]] || { printf 'Publishing is only allowed from the GitHub Actions workflow.\n' >&2; exit 6; }
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must identify this fork}"
  git -C "$repo_root" remote get-url upstream >/dev/null 2>&1 || \
    git -C "$repo_root" remote add upstream "https://github.com/$upstream.git"
  git -C "$repo_root" fetch upstream --tags '+refs/heads/main:refs/remotes/upstream/main'
  git -C "$repo_root" fetch origin --tags
  git -C "$repo_root" switch -C main "${GITHUB_SHA:-HEAD}"
  git -C "$repo_root" merge --no-edit upstream/main
  git -C "$repo_root" push origin HEAD:main
  git -C "$repo_root" push origin --tags

  release_tag="$source_tag.mediapager"
  if ! git -C "$repo_root" show-ref --verify --quiet "refs/tags/$release_tag"; then
    git -C "$repo_root" tag -a "$release_tag" "$source_tag" -m "Customized WASM build for upstream $source_tag ($source_commit)"
  fi
  git -C "$repo_root" push origin "refs/tags/$release_tag"

  if gh release view "$release_tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    gh release upload "$release_tag" "$archive" --repo "$GITHUB_REPOSITORY" --clobber
  else
    gh release create "$release_tag" "$archive" --repo "$GITHUB_REPOSITORY" \
      --title "$tool WASM $source_tag (MediaPager)" \
      --notes "Customized WebAssembly artifact built from upstream tag $source_tag."
  fi
  printf 'Published %s from %s\n' "$release_tag" "$source_tag"
else
  printf 'Local build verified for %s %s; no fork changes or release were published.\n' "$tool" "$source_tag"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'source_tag=%s\nartifact=%s\nrelease_tag=%s.mediapager\n' "$source_tag" "$archive" "$source_tag" >> "$GITHUB_OUTPUT"
fi
printf 'Artifact: %s\n' "$archive"
