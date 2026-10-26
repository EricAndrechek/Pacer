#!/usr/bin/env bash
#
# fetch-forecast-weights.sh — put the forecast networks Pacer ships inside the
# app (Timestral-5M and -28M, Mistral AI) in Vendor/ForecastWeights/, pinned by
# revision and SHA-256. `make vendor` (so every build target) runs it first;
# project.yml copies the folder into Pacer.app/Contents/Resources/ForecastWeights/.
#
# The weights are never committed: the 28M file alone is 111 MB (GitHub refuses
# files over 100 MB) and every revision bump would stay in history forever. The
# larger Timestral sizes are not bundled at all; the app downloads them on first
# use (ArenaWeightStore.ensureAvailable) from the same pinned revisions.
#
# Each file comes from the first of: another worktree of this repo (an APFS
# clone, instant), the local Hugging Face cache (where research/arena keeps
# them), or https://huggingface.co/<repo>/resolve/<revision>/<file>. A copy
# that does not hash to its pin is deleted and the script fails.
#
# A no-op when every file is present at its pinned size (a `stat` per file), so
# it costs next to nothing on every build. `--verify` re-hashes what is there.
#
# The pins below must match ArenaWeightStore.pinned in
# PacerCore/Sources/PacerCore/Forecast/Arena/Kit/FM/ArenaWeightStore.swift;
# FMWeightsTests checks that they do.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/Vendor/ForecastWeights"
VERIFY=0
[ "${1:-}" = "--verify" ] && VERIFY=1

# weights id | file | sha256 | bytes
PINS=(
  "mistralai/Timestral-5M@bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f|config.json|b5f27f61513f8fd1a3aa996f3720d3679cb40bce5bcb08eb3dc320ce726e7c2f|904"
  "mistralai/Timestral-5M@bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f|model.safetensors|7ace108c4987e7f2a99a75a445240019d1d31c2117139d1bd05ffdfd25aca738|20843960"
  "mistralai/Timestral-5M@bdd20cfc15a3fea0e4cb5ccef37f8d3ca7aa335f|LICENSE|648194727930df730890e9f9affdbcc5c930d406d6829559b25ca3d5a973fc8c|1695"
  "mistralai/Timestral-28M@49b26409ac87b5935539a5d8ffe7f397b720db47|config.json|0cdf44b8ea981191de53078e0a5ecbbd437046bd939a546d5dbe17868f71281f|961"
  "mistralai/Timestral-28M@49b26409ac87b5935539a5d8ffe7f397b720db47|model.safetensors|dfc83c6220937ce5fc6687b35a4df94cd25e28a2cfe6fb92a23dad6301b2015d|111296464"
  "mistralai/Timestral-28M@49b26409ac87b5935539a5d8ffe7f397b720db47|LICENSE|648194727930df730890e9f9affdbcc5c930d406d6829559b25ca3d5a973fc8c|1695"
)

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
size() { stat -L -f %z "$1" 2>/dev/null || echo -1; }

# Other worktrees of this repo, to clone from.
others=()
while IFS= read -r line; do
  case "$line" in
    "worktree "*) wt="${line#worktree }"; [ "$wt" != "$REPO_ROOT" ] && others+=("$wt") ;;
  esac
done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null || true)

if [ -n "${HF_HUB_CACHE:-}" ]; then HF_HUB="$HF_HUB_CACHE"
elif [ -n "${HF_HOME:-}" ]; then HF_HUB="$HF_HOME/hub"
else HF_HUB="$HOME/.cache/huggingface/hub"; fi

fetched=0
for pin in "${PINS[@]}"; do
  IFS='|' read -r id file want bytes <<<"$pin"
  repo="${id%@*}"; rev="${id#*@}"
  dir="$DEST/$id"
  f="$dir/$file"
  if [ "$(size "$f")" = "$bytes" ]; then
    if [ $VERIFY = 0 ] || [ "$(sha "$f")" = "$want" ]; then continue; fi
    echo "==> $id/$file does not match its pin; fetching it again"
  fi
  mkdir -p "$dir"
  tmp="$dir/.$file.partial"
  rm -f "$tmp"
  src=""
  for wt in "${others[@]+"${others[@]}"}"; do
    if [ "$(size "$wt/Vendor/ForecastWeights/$id/$file")" = "$bytes" ]; then src="$wt/Vendor/ForecastWeights/$id/$file"; break; fi
  done
  org="${repo%/*}"; name="${repo#*/}"
  hf="$HF_HUB/models--$org--$name/snapshots/$rev/$file"
  if [ -n "$src" ]; then
    echo "==> $id/$file: cloning from $src"
    cp -c "$src" "$tmp" 2>/dev/null || cp "$src" "$tmp"
  elif [ "$(size "$hf")" = "$bytes" ]; then
    echo "==> $id/$file: copying from the Hugging Face cache"
    cp -cL "$hf" "$tmp" 2>/dev/null || cp -L "$hf" "$tmp"
  else
    echo "==> $id/$file: downloading from huggingface.co"
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmp" "https://huggingface.co/$repo/resolve/$rev/$file"
  fi
  got="$(sha "$tmp")"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    echo "error: $id/$file hashes to $got, not the pinned $want" >&2
    exit 1
  fi
  mv -f "$tmp" "$f"
  fetched=$((fetched + 1))
done
if [ $fetched -gt 0 ]; then echo "==> forecast weights ready in Vendor/ForecastWeights ($fetched file(s) fetched)"; fi
