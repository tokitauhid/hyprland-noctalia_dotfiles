<div align="center">
  <h1>🌌 Hyprland & Noctalia Environment</h1>
  <p>A complete, automated deployment repository for my personal Arch Linux environment.</p>
</div>

---

> [!WARNING]
> **CRITICAL WARNING**
> This repository and its accompanying install script are designed for **fresh Arch Linux installations**. 
> Running this on an existing system **WILL NUKE** your current active dotfiles. Existing directories (like `~/.config/hypr`, `~/.config/fish`, etc.) will be moved to backup folders, effectively taking over your configuration. **Do not run this on your daily driver unless you intend to completely replace your setup.**

## 🌟 Features

- **Window Manager:** [Hyprland](https://hyprland.org/)
- **Desktop Environment Shell:** [Noctalia](https://github.com/Noctalia)
- **Terminal:** [Kitty](https://sw.kovidgoyal.net/kitty/)
- **Shell:** [Fish](https://fishshell.com/) + [Starship](https://starship.rs/) prompt
- **System Monitor:** Btop & Fastfetch
- **Login Manager:** SDDM (Astronaut theme)

## 🚀 Installation

Clone this repository and run the `install.sh` script. **Do not run it as root!**

```bash
git clone https://github.com/yourusername/dotfiles.git ~/hyprland+noctalia_dotfiles
cd ~/hyprland+noctalia_dotfiles
./install.sh
```

### Script Options

You can run `./install.sh --help` to see all available options. The script handles:
- Setting up the **Chaotic AUR**.
- Building and installing an AUR helper (`paru` or `yay`).
- Installing all core and optional system packages.
- Deploying configuration files directly into `~/.config/`.

To run a completely non-interactive installation (assuming defaults for all prompts):
```bash
./install.sh -y
```

## 📂 Structure

- `hypr/` - Hyprland window manager configurations
- `noctalia/` - Noctalia Shell configurations
- `fish/` - Shell configuration and environment variables
- `kitty/` - Terminal emulator configuration
- `sddm/` - Login screen theme and configuration
- `btop/` & `fastfetch/` - Terminal utilities setup

## 🛠️ Post-Installation

1. **Monitors**: Run `nwg-displays` to arrange your monitors and generate the `monitors.conf` file tailored to your specific hardware setup.
2. **SDDM**: If you opted to install the SDDM stack, ensure you disable any existing display managers before rebooting.
