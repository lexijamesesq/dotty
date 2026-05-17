#!/usr/bin/env bash
# Hardcoded user path in a shipped script — Revise expected.

CONFIG_DIR="/Users/somebody/.config/myapp"
LINUX_DATA="/home/someuser/data"

mkdir -p "$CONFIG_DIR"
ls "$LINUX_DATA"
