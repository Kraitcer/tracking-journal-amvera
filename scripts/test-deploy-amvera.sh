#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/amvera-deploy-test.XXXXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
export GIT_CONFIG_GLOBAL="$temp_dir/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export VITE_GOOGLE_CLIENT_ID=123-test.apps.googleusercontent.com
git config --global user.name "Deployment test"
git config --global user.email "deployment-test@example.invalid"
git config --global core.autocrlf false

fail() {
  echo "Test failed: $*" >&2
  exit 1
}

assert_file() {
  git --git-dir="$remote" cat-file -e "master:$1" || fail "Missing deployed file: $1"
}

assert_absent() {
  if git --git-dir="$remote" cat-file -e "master:$1" 2>/dev/null; then
    fail "Unexpected deployed file: $1"
  fi
}

deploy() {
  bash "$script_dir/deploy-amvera.sh" "$temp_dir/source" "$remote"
}

expect_failure() {
  if deploy > "$temp_dir/failure.log" 2>&1; then
    fail "Deployment should have failed: $1"
  fi
  grep -q "$1" "$temp_dir/failure.log" || {
    cat "$temp_dir/failure.log" >&2
    fail "Missing expected error: $1"
  }
}

git init --initial-branch=master "$temp_dir/client"
mkdir -p "$temp_dir/client/src" "$temp_dir/client/uploads" "$temp_dir/client/node_modules"
for file in package.json package-lock.json index.html src/main.tsx; do
  printf 'fixture\n' > "$temp_dir/client/$file"
done
printf 'dummy-public-test-value\n' > "$temp_dir/client/.env.production"
printf 'dummy-upload\n' > "$temp_dir/client/uploads/image.png"
printf 'dummy-dependency\n' > "$temp_dir/client/node_modules/dependency.js"
printf 'dummy-log\n' > "$temp_dir/client/build.log"
git -C "$temp_dir/client" add .
git -C "$temp_dir/client" commit -m "Client fixture"

git init --initial-branch=master "$temp_dir/server"
mkdir -p "$temp_dir/server/src" "$temp_dir/server/prisma"
for file in package.json package-lock.json src/main.ts prisma/schema.prisma; do
  printf 'fixture\n' > "$temp_dir/server/$file"
done
git -C "$temp_dir/server" add .
git -C "$temp_dir/server" commit -m "Server fixture"

git init --initial-branch=master "$temp_dir/source"
printf 'FROM node:22\nARG VITE_GOOGLE_CLIENT_ID\n' > "$temp_dir/source/Dockerfile.amvera"
printf 'run:\n  containerPort: 5000\n' > "$temp_dir/source/amvera.yaml"
printf '**/.env*\n' > "$temp_dir/source/.dockerignore"
printf 'local-only\n' > "$temp_dir/source/docker-compose.yml"
git -C "$temp_dir/source" -c protocol.file.allow=always submodule add "$temp_dir/client" client
git -C "$temp_dir/source" -c protocol.file.allow=always submodule add \
  "$temp_dir/server" tracking-journal-server-nest-postgresql
git -C "$temp_dir/source" add .
git -C "$temp_dir/source" commit -m "Parent fixture"
printf 'uncommitted\n' >> "$temp_dir/source/client/src/main.tsx"
printf 'local-env\n' > "$temp_dir/source/client/.env.local"

remote="$temp_dir/amvera.git"
git init --bare --initial-branch=master "$remote"
deploy
assert_file client/src/main.tsx
assert_file tracking-journal-server-nest-postgresql/prisma/schema.prisma
assert_absent .gitmodules
assert_absent docker-compose.yml
assert_absent client/.env.production
assert_absent client/.env.local
assert_absent client/node_modules/dependency.js
assert_absent client/uploads/image.png
assert_absent client/build.log
[[ "$(git --git-dir="$remote" show master:client/src/main.tsx)" == fixture ]] ||
  fail "Uncommitted edits were exported"
[[ "$(git --git-dir="$remote" ls-tree master client)" == 040000* ]] ||
  fail "Client is still a Git link"
git --git-dir="$remote" show master:Dockerfile.amvera |
  grep -qx "ARG VITE_GOOGLE_CLIENT_ID=$VITE_GOOGLE_CLIENT_ID" ||
  fail "Public build configuration was not exported"
grep -qx 'ARG VITE_GOOGLE_CLIENT_ID' "$temp_dir/source/Dockerfile.amvera" ||
  fail "Source Dockerfile was changed"
first_commit="$(git --git-dir="$remote" rev-parse master)"
deploy
[[ "$(git --git-dir="$remote" rev-parse master)" == "$first_commit" ]] ||
  fail "Identical snapshot created another commit"

git clone "$remote" "$temp_dir/old-deployment"
printf 'stale configuration\n' > "$temp_dir/old-deployment/amvera.yml"
git -C "$temp_dir/old-deployment" update-index --add --cacheinfo \
  "160000,$(git -C "$temp_dir/source/client" rev-parse HEAD),old-client"
git -C "$temp_dir/old-deployment" add amvera.yml
git -C "$temp_dir/old-deployment" commit -m "Old deployment layout"
git -C "$temp_dir/old-deployment" push origin master
old_commit="$(git --git-dir="$remote" rev-parse master)"
deploy
assert_absent amvera.yml
assert_absent old-client
[[ "$(git --git-dir="$remote" rev-parse master^)" == "$old_commit" ]] ||
  fail "Remote history was not preserved"
[[ -z "$(git --git-dir="$remote" ls-tree -r master | grep '^160000 ' || true)" ]] ||
  fail "Deployment contains Git links"

VITE_GOOGLE_CLIENT_ID='invalid value' expect_failure "Invalid public Google client ID"
git -C "$temp_dir/source/client" add src/main.tsx
git -C "$temp_dir/source/client" commit -m "Unpinned client change"
expect_failure "Submodule does not match its pinned commit"
git -C "$temp_dir/source" add client
git -C "$temp_dir/source" commit -m "Pin updated client"
git -C "$temp_dir/source/tracking-journal-server-nest-postgresql" rm package-lock.json
git -C "$temp_dir/source/tracking-journal-server-nest-postgresql" commit -m "Missing lock fixture"
git -C "$temp_dir/source" add tracking-journal-server-nest-postgresql
git -C "$temp_dir/source" commit -m "Pin broken server"
expect_failure "Required source file is missing or empty"
[[ "$(git --git-dir="$remote" rev-parse master^)" == "$old_commit" ]] ||
  fail "Failed validation modified the remote"

echo "PASS: flattened files, exclusions, pinned commits, clean source, public build config,"
echo "empty remote, idempotency, legacy layout migration, history preservation and validation failures."

if [[ "${1:-}" == --actual-source ]]; then
  remote="$temp_dir/actual-source.git"
  git init --bare --initial-branch=master "$remote"
  bash "$script_dir/deploy-amvera.sh" "$script_dir/.." "$remote"
  assert_file client/package-lock.json
  assert_file tracking-journal-server-nest-postgresql/prisma/schema.prisma
  assert_absent .gitmodules
  assert_absent client/.env
  [[ -z "$(git --git-dir="$remote" ls-tree -r master | grep '^160000 ' || true)" ]] ||
    fail "Actual project export contains Git links"
  echo "PASS: actual project exported with real client/server files and no Git links."
fi
