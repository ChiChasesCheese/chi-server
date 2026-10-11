#!/usr/bin/env bash
# Before chi up photos: make sure the upstream compose file is downloaded and .env paths are in sync
exec "$(dirname "$0")/fetch.sh"
