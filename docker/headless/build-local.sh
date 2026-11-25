#!/bin/sh
# Builds fliva/budgero-headless:dev from a local fork worktree (SRC_MODE=local): only committed HEAD goes in.
# Usage: docker/headless/build-local.sh [worktree]   (default ../budgero-wt-headless from the repo root)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
wt=${1:-$here/../../../budgero-wt-headless}
git -C "$wt" archive --format=tar -o "$here/src.tar" HEAD
docker build --build-arg SRC_MODE=local \
  --build-arg SOURCE_REVISION="$(git -C "$wt" describe --tags --match 'headless-v*' --always --dirty)" \
  -t fliva/budgero-headless:dev "$here"
