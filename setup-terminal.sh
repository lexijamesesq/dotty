#!/bin/bash

DOTTY="$HOME/bin/dotty"
DOTTY_PRIVATE="$HOME/bin/dotty-private"

echo "Setting up Terminal with GitHub-synced Configs"

# Remove any existing .zshrc so stow can symlink ours in
rm -f ~/.zshrc

# Ensure ~/.config and ~/.ssh directories exist
mkdir -p ~/.config ~/.ssh
mkdir -p "$HOME/Library/Application Support/com.mitchellh.ghostty"
chmod 700 ~/.ssh

# Stow private dotfiles (zshrc, gitconfig, ssh config, etc.)
echo "Creating symlinks with Stow..."
stow -d ~/bin -t ~ dotty-private
echo "Symlinks created."

# Symlink public dotfiles not managed by stow
ln -sfn "$DOTTY/.config/starship.toml" ~/.config/starship.toml
echo "Starship config linked."

# Symlink Ghostty config
ln -sfn "$DOTTY_PRIVATE/ghostty/config" "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
echo "Ghostty config linked."

# Set up Claude Code profile directories
if [ -f "$DOTTY/setup-claude-profiles.sh" ]; then
  echo "Setting up Claude Code profiles..."
  bash "$DOTTY/setup-claude-profiles.sh"
fi

# Set up SSH hardening (requires sudo, public key must be in place)
if [ -f "$DOTTY/setup-ssh.sh" ]; then
  echo "Setting up SSH hardening..."
  bash "$DOTTY/setup-ssh.sh"
fi

echo "Restarting shell..."
exec zsh
