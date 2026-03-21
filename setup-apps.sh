#!/bin/bash

echo "Running app setup..."

# Install Rosetta 2 (assuming Apple Silicon Mac)
echo "Installing Rosetta 2..."
sudo softwareupdate --install-rosetta --agree-to-license
echo "Rosetta 2 installed."

# Run Brewfile to install apps
echo "Installing applications from Brewfile..."
brew bundle --file=~/bin/dotty-private/Brewfile
echo "Application installation complete."

# Switch GitHub remotes to SSH (since 1Password will be installed via Brewfile)
echo "Switching Git remotes to SSH..."
git -C ~/bin/dotty remote set-url origin git@github.com:lexijamesesq/dotty.git 2>/dev/null
git -C ~/bin/dotty-private remote set-url origin git@github.com:lexijamesesq/dotty-private.git 2>/dev/null
echo "Git remotes updated to SSH."

echo "App setup complete. You can now run setup-terminal.sh."
