#!/bin/bash

DOTTY="$HOME/bin/dotty"
DOTTY_PRIVATE="$HOME/bin/dotty-private"

echo "Setting up Terminal with GitHub-synced Configs"

# Ensure Oh My Zsh is installed
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  echo "Installing Oh My Zsh..."
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# Remove existing .zshrc if it was created by Oh My Zsh
rm -f ~/.zshrc

# Ensure ~/.config and ~/.ssh directories exist
mkdir -p ~/.config ~/.ssh
chmod 700 ~/.ssh

# Stow private dotfiles (zshrc, gitconfig, ssh config, etc.)
echo "Creating symlinks with Stow..."
stow -d ~/bin -t ~ dotty-private
echo "Symlinks created."

# Symlink public dotfiles not managed by stow
ln -sf "$DOTTY/.config/starship.toml" ~/.config/starship.toml
echo "Starship config linked."

# Ensure custom plugin directory exists
ZSH_CUSTOM="$HOME/.oh-my-zsh/custom/plugins"
mkdir -p "$ZSH_CUSTOM"

# Install Zsh plugins if not present
if [ ! -d "$ZSH_CUSTOM/zsh-autosuggestions" ]; then
  echo "Installing zsh-autosuggestions..."
  git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/zsh-autosuggestions"
fi

if [ ! -d "$ZSH_CUSTOM/zsh-syntax-highlighting" ]; then
  echo "Installing zsh-syntax-highlighting..."
  git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/zsh-syntax-highlighting"
fi

echo "Oh My Zsh setup complete."

# Ensure iTerm loads preferences from custom folder
echo "Configuring iTerm preferences..."
defaults write com.googlecode.iterm2 PrefsCustomFolder -string "$DOTTY_PRIVATE/iterm/"
defaults write com.googlecode.iterm2 LoadPrefsFromCustomFolder -bool true
echo "iTerm configuration updated."

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
