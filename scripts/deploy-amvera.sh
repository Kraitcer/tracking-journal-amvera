#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "Deployment error: $*" >&2
  exit 1
}

[[ $# == 2 ]] || fail "Usage: bash scripts/deploy-amvera.sh SOURCE_DIR REMOTE_URL"
source_dir="$(cd "$1" && pwd)"
remote_url="$2"
source_commit="$(git -C "$source_dir" rev-parse HEAD)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/amvera-deploy.XXXXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
snapshot="$temp_dir/snapshot"
delivery="$temp_dir/delivery"
mkdir "$snapshot"

export_repo() {
  local repo="$1" destination="$2"
  local entry metadata path mode expected actual
  mkdir -p "$destination"
  git -C "$repo" archive HEAD |
    tar -x -C "$destination" \
      --exclude='.git' --exclude='.gitmodules' --exclude='.github' \
      --exclude='.env' --exclude='.env.*' \
      --exclude='node_modules' --exclude='dist' --exclude='coverage' \
      --exclude='uploads' --exclude='*.log' --exclude='*.tsbuildinfo'
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    mode="${metadata%% *}"
    [[ "$mode" == 160000 ]] || continue
    expected="${metadata##* }"
    [[ -d "$repo/$path" ]] || fail "Submodule is missing: $repo/$path"
    [[ -z "$(git -C "$repo/$path" rev-parse --show-prefix)" ]] ||
      fail "Submodule is not initialized: $repo/$path"
    actual="$(git -C "$repo/$path" rev-parse HEAD)"
    [[ "$actual" == "$expected" ]] || fail "Submodule does not match its pinned commit: $path"
    export_repo "$repo/$path" "$destination/$path"
  done < <(git -C "$repo" ls-tree -rz HEAD)
}

# Only deployment configuration belongs at the root of the exported snapshot.
git -C "$source_dir" archive HEAD Dockerfile.amvera amvera.yaml .dockerignore |
  tar -x -C "$snapshot"
for module in client tracking-journal-server-nest-postgresql; do
  pinned="$(git -C "$source_dir" rev-parse "HEAD:$module")"
  [[ "$(git -C "$source_dir" ls-tree HEAD "$module")" == 160000* ]] ||
    fail "Expected a submodule at $module"
  [[ -d "$source_dir/$module" ]] || fail "Submodule is missing: $module"
  [[ -z "$(git -C "$source_dir/$module" rev-parse --show-prefix)" ]] ||
    fail "Submodule is not initialized: $module"
  [[ "$(git -C "$source_dir/$module" rev-parse HEAD)" == "$pinned" ]] ||
    fail "Submodule does not match its pinned commit: $module"
  export_repo "$source_dir/$module" "$snapshot/$module"
done

for required in \
  client/package.json client/package-lock.json client/index.html client/src/main.tsx \
  tracking-journal-server-nest-postgresql/package.json \
  tracking-journal-server-nest-postgresql/package-lock.json \
  tracking-journal-server-nest-postgresql/src/main.ts \
  tracking-journal-server-nest-postgresql/prisma/schema.prisma; do
  [[ -s "$snapshot/$required" ]] || fail "Required source file is missing or empty: $required"
done

# Vite consumes this public value during the Amvera build, not at runtime.
google_id="${VITE_GOOGLE_CLIENT_ID:-}"
[[ "$google_id" =~ ^[a-zA-Z0-9._-]*$ ]] || fail "Invalid public Google client ID"
[[ "$(grep -c '^ARG VITE_GOOGLE_CLIENT_ID$' "$snapshot/Dockerfile.amvera")" == 1 ]] ||
  fail "Expected exactly one Google client ID build argument in Dockerfile.amvera"
sed "s/^ARG VITE_GOOGLE_CLIENT_ID$/ARG VITE_GOOGLE_CLIENT_ID=$google_id/" \
  "$snapshot/Dockerfile.amvera" > "$temp_dir/Dockerfile.amvera"
mv "$temp_dir/Dockerfile.amvera" "$snapshot/Dockerfile.amvera"

if git ls-remote --exit-code "$remote_url" refs/heads/master > "$temp_dir/remote-ref"; then
  git clone --single-branch --branch master "$remote_url" "$delivery"
  git -C "$delivery" rm -r --ignore-unmatch -- .
else
  status=$?
  [[ "$status" == 2 ]] || fail "Cannot read the Amvera repository (git exit code $status)"
  git init --initial-branch=master "$delivery"
  git -C "$delivery" remote add origin "$remote_url"
fi

tar -C "$snapshot" -cf - . | tar -C "$delivery" -xf -
git -C "$delivery" config user.name "Amvera deployment"
git -C "$delivery" config user.email "223556219+Copilot@users.noreply.github.com"
git -C "$delivery" add --all --force
[[ -z "$(git -C "$delivery" ls-files --stage | grep '^160000 ' || true)" ]] ||
  fail "Deployment still contains submodule links"
if git -C "$delivery" diff --cached --quiet; then
  echo "Amvera already contains this deployment snapshot."
  exit 0
fi
git -C "$delivery" commit -m "Deploy source $source_commit" \
  -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git -C "$delivery" push origin HEAD:refs/heads/master
echo "Source delivered. Verify build logs, application logs and the public URL in Amvera."
