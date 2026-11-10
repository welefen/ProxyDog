#!/usr/bin/env bash
# Quick debug check: build the executable.
source "$(cd "$(dirname "$0")" && pwd)/env.sh"
pd_build -c debug "$@"
