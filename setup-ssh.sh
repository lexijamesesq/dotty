#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_DIR="$HOME/.ssh"
PUBKEY_FILE="$SSH_DIR/home-network.pub"
SSHD_CONF="/etc/ssh/sshd_config.d/000-local.conf"
NETWORK_CONF="$HOME/bin/dotty-private/network.conf"

# Load machine IPs from private config
if [ ! -f "$NETWORK_CONF" ]; then
  echo "ERROR: $NETWORK_CONF not found."
  echo ""
  echo "Create it with your machine IPs:"
  echo "  ALLOWED_IPS=\"10.0.1.50,10.0.1.51,10.0.1.53\""
  echo ""
  echo "Then re-run this script."
  exit 1
fi
source "$NETWORK_CONF"

if [ -z "${ALLOWED_IPS:-}" ]; then
  echo "ERROR: ALLOWED_IPS not set in $NETWORK_CONF"
  exit 1
fi

echo "=== SSH Hardening Setup ==="

# --- Prerequisites ---
if [ ! -f "$PUBKEY_FILE" ]; then
  echo ""
  echo "ERROR: $PUBKEY_FILE not found."
  echo ""
  echo "Export your inter-machine SSH public key from 1Password:"
  echo "  1. Open 1Password > find your SSH key"
  echo "  2. Copy the public key"
  echo "  3. Save it to $PUBKEY_FILE"
  echo ""
  echo "Then re-run this script."
  exit 1
fi

PUBKEY=$(cat "$PUBKEY_FILE")
echo "Using public key: ${PUBKEY:0:40}..."
echo "Allowed IPs: $ALLOWED_IPS"

# --- SSH Client Config ---
echo "SSH client config: managed by stow"

# --- Authorized Keys ---
echo ""
echo "Setting up authorized_keys..."
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

AK_FILE="$SSH_DIR/authorized_keys"
AK_ENTRY="restrict,pty,from=\"$ALLOWED_IPS\" $PUBKEY"

# Check if key already present (by fingerprint)
KEY_FINGERPRINT=$(ssh-keygen -lf "$PUBKEY_FILE" 2>/dev/null | awk '{print $2}')
if [ -f "$AK_FILE" ] && grep -q "$KEY_FINGERPRINT" <(ssh-keygen -lf "$AK_FILE" 2>/dev/null); then
  echo "  Key already in authorized_keys (fingerprint: $KEY_FINGERPRINT)"
  echo "  Updating entry with current IP restrictions..."
  grep -v "$(echo "$PUBKEY" | awk '{print $2}')" "$AK_FILE" > "$AK_FILE.tmp" 2>/dev/null || true
  echo "$AK_ENTRY" >> "$AK_FILE.tmp"
  mv "$AK_FILE.tmp" "$AK_FILE"
else
  echo "$AK_ENTRY" >> "$AK_FILE"
  echo "  Added key with restrict,from=\"$ALLOWED_IPS\""
fi
chmod 600 "$AK_FILE"

# --- SSHD Hardening ---
echo ""
echo "Installing sshd hardening config..."
SSHD_SOURCE="$SCRIPT_DIR/ssh-sshd-hardening.conf"
if [ ! -f "$SSHD_SOURCE" ]; then
  echo "ERROR: $SSHD_SOURCE not found"
  exit 1
fi

if [ -f "$SSHD_CONF" ]; then
  if diff -q "$SSHD_SOURCE" "$SSHD_CONF" >/dev/null 2>&1; then
    echo "  $SSHD_CONF already up to date"
  else
    echo "  Updating $SSHD_CONF (sudo required)"
    sudo cp "$SSHD_SOURCE" "$SSHD_CONF"
    echo "  Restarting sshd..."
    sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
  fi
else
  echo "  Installing $SSHD_CONF (sudo required)"
  sudo cp "$SSHD_SOURCE" "$SSHD_CONF"
  echo "  Restarting sshd..."
  sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
fi

# --- Verification ---
echo ""
echo "=== Verification ==="
echo "SSH client config:"
grep "^Host " "$SSH_DIR/config" 2>/dev/null | sed 's/^/  /'
echo "Authorized keys:"
wc -l < "$AK_FILE" | xargs -I{} echo "  {} entries"
echo "SSHD hardening:"
if [ -f "$SSHD_CONF" ]; then
  echo "  $SSHD_CONF installed"
  grep "PasswordAuthentication" "$SSHD_CONF" | sed 's/^/  /'
else
  echo "  NOT installed"
fi
echo ""
echo "=== Done ==="
echo "Note: Remote Login must be enabled in System Settings > General > Sharing"
