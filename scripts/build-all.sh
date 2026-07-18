#!/usr/bin/env sh
set -eu

project_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
exec just --justfile "$project_dir/justfile" build-all
