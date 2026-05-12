#!/bin/bash

# =======================================================================
# Automated Hyprland + Noctalia Environment Installer
# =======================================================================

echo "Starting installation process for Hyprland + Noctalia environment..."

# 1. Update the system
echo "Updating package databases..."
paru -Syu --noconfirm

# 2. Install required packages
PACKAGES=(
    # Core Hyprland Ecosystem
    "hyprland"
    "hyprpaper"
    "hyprlock"
    "hypridle"
    "wl-clipboard"
    "cliphist"
    "grim"
    "slurp"
    "hyprshot"
    "kitty"
    "nautilus"
    
    # Authentication Agents
    "polkit"
    "polkit-kde-agent"
    "hyprpolkitagent"
    
    # Desktop Shell & Display Manager
    "noctalia-shell"
    "sddm-theme-noctalia-git"
    "nwg-displays"
    
    # Useful CLI/TUI Tools
    "bash"
    "fish"
    "starship"
    "bat"
    "btop"
    "eza"
    "fastfetch"
    "fd"
    "fzf"
    "git"
    "ripgrep"
)

echo "Installing required packages..."
paru -S --needed --noconfirm "${PACKAGES[@]}"

# 3. Copy configuration files to ~/.config
echo "Deploying configuration files..."

CONFIG_DIR="$HOME/.config"
REPO_DIR="$(dirname "$(realpath "$0")")"

# Ensure ~/.config exists
mkdir -p "$CONFIG_DIR"

# Copy directories
echo "Copying config directories..."
cp -r "$REPO_DIR/hypr" "$CONFIG_DIR/"
cp -r "$REPO_DIR/kitty" "$CONFIG_DIR/"
cp -r "$REPO_DIR/fastfetch" "$CONFIG_DIR/"
cp -r "$REPO_DIR/btop" "$CONFIG_DIR/"
cp -r "$REPO_DIR/fish" "$CONFIG_DIR/"
cp -r "$REPO_DIR/noctalia" "$CONFIG_DIR/"

# Copy files
echo "Copying config files..."
cp "$REPO_DIR/starship.toml" "$CONFIG_DIR/"

echo "======================================================================="
echo "Installation complete!"
echo "Your Hyprland + Noctalia environment is ready."
echo "======================================================================="
