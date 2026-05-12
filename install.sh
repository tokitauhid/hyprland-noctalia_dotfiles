#!/usr/bin/env bash
# =======================================================================
# Hyprland + Noctalia environment installer (Arch / Arch-based)
# =======================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"

# -----------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------
# Logs go to stderr so command substitutions (e.g. aur="$(ensure_aur_helper)") stay clean.
log_info()  { printf '\033[0;32m[INFO]\033[0m %s\n' "$*" >&2; }
log_warn()  { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }
log_err()   { printf '\033[0;31m[ERR ]\033[0m %s\n' "$*" >&2; }
log_step()  { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }

# -----------------------------------------------------------------------
# Options (override with env or flags)
# -----------------------------------------------------------------------
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--assume-yes) ASSUME_YES=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./install.sh [options]

  -y, --yes, --assume-yes   Non-interactive: no Chaotic-AUR prompt; auto-builds
                            paru if no AUR helper exists; runs full upgrade;
                            installs core packages; optional packages/features only if
                            DOTFILES_OPTIONAL is set (see below). Deployed
                            configs under ~/.config rewrite /home/tokit to your
                            HOME (repository files are not modified).

  With -y, set CHAOTIC_AUR=1 to add Chaotic AUR non-interactively.

Environment:
  CHAOTIC_AUR=0|1              Add Chaotic AUR (requires sudo) when 1.
  AUR_HELPER=paru|yay          Force helper (must exist in PATH).
  DOTFILES_OPTIONAL=none       With -y: skip optional packages/features (default).
  DOTFILES_OPTIONAL=all        With -y: install every optional package and feature.
  DOTFILES_OPTIONAL=a,b,...    With -y: comma-separated names, e.g.
                               steam,discord,sddm-stack,hyprland-plugin-hyprexpo
EOF
      exit 0
      ;;
  esac
done

# -----------------------------------------------------------------------
# Prompts
# -----------------------------------------------------------------------
prompt_yn() {
  # $1 question, $2 default y|n
  local q="$1" def="${2:-n}" ans hint="[y/N]"
  [[ "$def" == "y" ]] && hint="[Y/n]"
  [[ "$ASSUME_YES" -eq 1 ]] && { [[ "$def" == "y" ]] && return 0 || return 1; }
  while true; do
    read -r -p "$q $hint: " ans || true
    ans="$(printf '%s' "${ans:-}" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "$ans" ]]; then
      [[ "$def" == "y" ]] && return 0 || return 1
    fi
    case "$ans" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) log_warn "Please answer y or n." ;;
    esac
  done
}

prompt_choice() {
  # Sets REPLY to 1-based index or empty on default (menus on stderr for safe $(...) capture)
  local prompt="$1" ; shift
  local options=("$@") i
  [[ "$ASSUME_YES" -eq 1 ]] && { REPLY=1; return 0; }
  printf '%s\n' "$prompt" >&2
  i=1
  for o in "${options[@]}"; do
    printf '  %d) %s\n' "$i" "$o" >&2
    ((i++)) || true
  done
  read -r -p "Choice [1]: " REPLY || true
  REPLY="${REPLY:-1}"
}

# -----------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------
require_not_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    log_err "Do not run this script as root. Run as your normal user (sudo is used only when needed)."
    exit 1
  fi
}

require_arch_like() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    if [[ "${ID:-}" == "arch" ]] || [[ "${ID:-}" == "cachyos" ]] || [[ "${ID_LIKE:-}" == *arch* ]]; then
      return 0
    fi
  fi
  log_warn "This installer targets Arch Linux (or Arch-based distros). Detected OS may be unsupported."
  if ! prompt_yn "Continue anyway?" "n"; then
    exit 1
  fi
}

have_sudo() {
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null || sudo -v
}

# -----------------------------------------------------------------------
# Chaotic AUR
# -----------------------------------------------------------------------
chaotic_already_configured() {
  [[ -f /etc/pacman.conf ]] && grep -q '^\[chaotic-aur\]' /etc/pacman.conf
}

setup_chaotic_aur() {
  if chaotic_already_configured; then
    log_info "Chaotic AUR is already present in /etc/pacman.conf."
    return 0
  fi
  log_step "Configuring Chaotic AUR (requires sudo)…"
  have_sudo
  sudo pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
  sudo pacman-key --lsign-key 3056513887B78AEB
  sudo pacman -U --needed --noconfirm \
    'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' \
    'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
  if ! grep -q '^\[chaotic-aur\]' /etc/pacman.conf 2>/dev/null; then
    echo | sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF
  fi
  log_step "Refreshing pacman databases after adding Chaotic AUR…"
  sudo pacman -Sy
  log_info "Chaotic AUR configured."
}

maybe_setup_chaotic_aur() {
  local want="${CHAOTIC_AUR:-}"
  if [[ "$want" == "1" ]]; then
    setup_chaotic_aur
    return
  fi
  if [[ "$want" == "0" ]]; then
    return
  fi
  if chaotic_already_configured; then
    log_info "Chaotic AUR already configured."
    return
  fi
  echo
  log_info "Chaotic AUR provides prebuilt binaries for many AUR packages (faster installs)."
  if prompt_yn "Add and enable the Chaotic AUR repository?" "n"; then
    setup_chaotic_aur
  else
    log_info "Skipping Chaotic AUR."
  fi
}

# -----------------------------------------------------------------------
# AUR helper (must not prompt inside command substitution — subshell breaks read)
# -----------------------------------------------------------------------
install_aur_helper_from_aur() {
  local choice="$1" builddir name url
  builddir="$(mktemp -d "${TMPDIR:-/tmp}/aur-helper.XXXXXX")"
  trap 'rm -rf "$builddir"' EXIT

  case "$choice" in
    paru) name=paru; url='https://aur.archlinux.org/paru.git' ;;
    yay)  name=yay;  url='https://aur.archlinux.org/yay.git'  ;;
    *) log_err "Invalid AUR helper choice."; exit 1 ;;
  esac

  log_step "Installing build prerequisites (base-devel, git)…"
  have_sudo
  sudo pacman -S --needed --noconfirm base-devel git

  log_step "Cloning and building $name (this can take a few minutes)…"
  git clone --depth 1 "$url" "$builddir/$name"
  ( cd "$builddir/$name" && makepkg -si --noconfirm )

  trap - EXIT
  rm -rf "$builddir"
}

ensure_aur_helper() {
  local helper picked has_paru=0 has_yay=0

  if [[ -n "${AUR_HELPER:-}" ]]; then
    case "${AUR_HELPER,,}" in
      paru)
        command -v paru >/dev/null 2>&1 || { log_err "AUR_HELPER=paru but paru is not in PATH."; exit 1; }
        log_info "Using AUR helper: paru (from AUR_HELPER)"
        echo paru
        return
        ;;
      yay)
        command -v yay >/dev/null 2>&1 || { log_err "AUR_HELPER=yay but yay is not in PATH."; exit 1; }
        log_info "Using AUR helper: yay (from AUR_HELPER)"
        echo yay
        return
        ;;
      *)
        log_err "AUR_HELPER must be paru or yay."
        exit 1
        ;;
    esac
  fi

  command -v paru >/dev/null 2>&1 && has_paru=1
  command -v yay  >/dev/null 2>&1 && has_yay=1

  if [[ "$has_paru" -eq 1 && "$has_yay" -eq 1 ]]; then
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      picked=paru
    else
      printf '\n' >&2
      prompt_choice "Both paru and yay are installed. Which should this script use?" \
        "paru" \
        "yay"
      case "${REPLY:-1}" in
        1) picked=paru ;;
        2) picked=yay ;;
        *) log_err "Invalid choice."; exit 1 ;;
      esac
    fi
    log_info "Using AUR helper: $picked"
    echo "$picked"
    return
  fi
  if [[ "$has_paru" -eq 1 ]]; then
    log_info "Using AUR helper: paru"
    echo paru
    return
  fi
  if [[ "$has_yay" -eq 1 ]]; then
    log_info "Using AUR helper: yay"
    echo yay
    return
  fi

  log_warn "No AUR helper found (paru / yay)."
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log_step "Non-interactive mode: building and installing paru…"
    install_aur_helper_from_aur paru
    if command -v paru >/dev/null 2>&1; then
      log_info "Using AUR helper: paru (auto-installed)"
      echo paru
      return
    fi
    log_err "Failed to auto-install paru. Install paru or yay, or set AUR_HELPER=paru|yay."
    exit 1
  fi

  printf '\n' >&2
  prompt_choice "Install an AUR helper now?" \
    "paru (recommended)" \
    "yay" \
    "Quit — I will install paru/yay myself and re-run this script"

  case "${REPLY:-1}" in
    1) helper=paru ;;
    2) helper=yay ;;
    3) log_info "Exiting. Install paru or yay, then run ./install.sh again."; exit 0 ;;
    *) log_err "Invalid choice."; exit 1 ;;
  esac

  install_aur_helper_from_aur "$helper"
  if ! command -v "$helper" >/dev/null 2>&1; then
    log_err "$helper is still not in PATH after install."
    exit 1
  fi
  echo "$helper"
}

# -----------------------------------------------------------------------
# Packages
# -----------------------------------------------------------------------
PACKAGES_CORE=(
  hyprland hyprpaper hyprlock hypridle
  wl-clipboard cliphist grim slurp hyprshot
  kitty nautilus
  polkit polkit-kde-agent hyprpolkitagent
  noctalia-shell nwg-displays
  bash fish starship bat btop eza fastfetch fd fzf git ripgrep
  playerctl pamixer satty uwsm libnotify jq polkit-gnome
  ttf-adwaita ttf-jetbrains-mono-nerd
  xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
  qt6ct wtype cmake
)

# Optional: "package|title|one-line description" (asked one-by-one interactively;
# under -y controlled by DOTFILES_OPTIONAL — see help).
OPTIONAL_PACKAGES=(
  "hyprland-plugin-hyprexpo|HyprExpo plugin (AUR)|Workspace overview (Super+D); matches the hyprexpo plugin block and avoids manual hyprpm builds."
  "pipewire|PipeWire|Low-latency audio/video; use if you need sound on a minimal install."
  "wireplumber|WirePlumber|Session manager for PipeWire (devices, routing, policies)."
  "wlsunset|wlsunset|Blue-light / night temperature for Wayland; Noctalia Night Light can use it."
  "power-profiles-daemon|power-profiles-daemon|Laptop power profiles (balanced / performance)."
  "ddcutil|ddcutil|External monitor brightness over DDC/CI (optional Noctalia feature)."
  "steam|Steam|Valve game client; your Hypr autostart runs steam -silent (needs [multilib] enabled)."
  "discord|Discord|Voice/chat client; your Hypr autostart launches Discord."
  "code|Visual Studio Code|GUI editor referenced as \$EDITOR in keybinds."
  "helium-browser|Helium browser (AUR)|Chromium-based browser bound to Super+B in keybinds."
)

# Optional features: id|title|description (install matching packages + sudo /etc; id is not a pacman name).
OPTIONAL_FEATURES=(
  "sddm-stack|SDDM login screen|Copies repo sddm/ to /etc (same files as this maintainer's PC). Installs sddm, sddm-astronaut-theme, qt6-virtualkeyboard to match that config, then enables sddm.service (reboot or disable another DM)."
)

# Path baked into repo configs; rewritten only under ~/.config after copy (repo tree untouched).
LEGACY_REPO_HOME="/home/tokit"

escape_sed_repl() {
  printf '%s' "$1" | sed 's/[\/&|]/\\&/g'
}

fixup_deployed_paths() {
  local roots=(
    "$CONFIG_DIR/hypr"
    "$CONFIG_DIR/fish"
    "$CONFIG_DIR/noctalia"
    "$CONFIG_DIR/btop"
    "$CONFIG_DIR/kitty"
  )
  local esc_home
  esc_home="$(escape_sed_repl "$HOME")"
  if [[ "$HOME" == "$LEGACY_REPO_HOME" ]]; then
    log_info "HOME matches legacy snapshot ($LEGACY_REPO_HOME); skipping path rewrite."
    return 0
  fi
  log_step "Rewriting $LEGACY_REPO_HOME → $HOME in deployed configs…"
  local root fp
  for root in "${roots[@]}"; do
    [[ -e "$root" ]] || continue
    while IFS= read -r -d '' fp; do
      sed -i "s|${LEGACY_REPO_HOME}|${esc_home}|g" "$fp"
    done < <(grep -rlIZF "$LEGACY_REPO_HOME" "$root" 2>/dev/null || true)
  done
}

fixup_fish_cachyos_line() {
  local f="$CONFIG_DIR/fish/config.fish"
  [[ -f "$f" ]] || return 0
  if grep -q '^if test -r /usr/share/cachyos-fish-config/cachyos-config.fish' "$f" 2>/dev/null; then
    return 0
  fi
  if ! grep -Fqx 'source /usr/share/cachyos-fish-config/cachyos-config.fish' "$f" 2>/dev/null; then
    return 0
  fi
  log_step "Making Fish CachyOS include optional (skip if file missing on this distro)…"
  awk '
    /^source \/usr\/share\/cachyos-fish-config\/cachyos-config\.fish$/ {
      print "if test -r /usr/share/cachyos-fish-config/cachyos-config.fish"
      print "    source /usr/share/cachyos-fish-config/cachyos-config.fish"
      print "end"
      next
    }
    { print }
  ' "$f" >"${f}.tmp.$$" && mv "${f}.tmp.$$" "$f"
}

optional_allowed_noninteractive() {
  local token="$1"
  local spec="${DOTFILES_OPTIONAL:-none}"
  if [[ "$spec" == "all" ]]; then
    return 0
  fi
  if [[ "$spec" == "none" || -z "${spec//[[:space:]]/}" ]]; then
    return 1
  fi
  local IFS=',' p
  read -ra parts <<< "$spec"
  for p in "${parts[@]}"; do
    p="${p//[[:space:]]/}"
    [[ "$p" == "$token" ]] && return 0
  done
  return 1
}

gather_optional_install_list() {
  local -n _gather_out="$1"
  local entry pkg title desc
  _gather_out=()
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log_info "Optional packages/features in -y mode: set DOTFILES_OPTIONAL=all, none, or comma-separated names (./install.sh -h)."
  fi
  for entry in "${OPTIONAL_PACKAGES[@]}"; do
    IFS='|' read -r pkg title desc <<< "$entry"
    if pacman -Qi "$pkg" &>/dev/null; then
      log_info "Already installed (skipping prompt): $pkg"
      continue
    fi
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      if optional_allowed_noninteractive "$pkg"; then
        _gather_out+=("$pkg")
      fi
      continue
    fi
    echo >&2
    log_info "Optional — $title"
    log_info "  $desc"
    if prompt_yn "Install package «$pkg»?" "n"; then
      _gather_out+=("$pkg")
    fi
  done
}

install_optional_packages() {
  local aur="$1"
  shift
  local pkgs=("$@")
  local p
  ((${#pkgs[@]})) || return 0
  log_step "Installing selected optional packages…"
  for p in "${pkgs[@]}"; do
    log_step "Optional: $p …"
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      "$aur" -S --needed --noconfirm "$p" || log_warn "Install failed for $p (see above). Continuing."
    else
      "$aur" -S --needed "$p" || log_warn "Install failed for $p (see above). Continuing."
    fi
  done
}

gather_optional_feature_list() {
  local -n _feat_out="$1"
  local entry id title desc
  _feat_out=()
  for entry in "${OPTIONAL_FEATURES[@]}"; do
    IFS='|' read -r id title desc <<< "$entry"
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      if optional_allowed_noninteractive "$id"; then
        _feat_out+=("$id")
      fi
      continue
    fi
    echo >&2
    log_info "Optional feature — $title"
    log_info "  $desc"
    if prompt_yn "Apply optional feature «$id»?" "n"; then
      _feat_out+=("$id")
    fi
  done
}

install_feature_sddm_stack() {
  local aur="$1"
  if [[ ! -d "$REPO_DIR/sddm" ]] || [[ ! -f "$REPO_DIR/sddm/sddm.conf" ]]; then
    log_warn "Repository is missing sddm/ (or sddm.conf); skipping SDDM setup."
    return 1
  fi
  log_step "SDDM stack: packages sddm, sddm-astronaut-theme, qt6-virtualkeyboard (match repo sddm/ config)…"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    "$aur" -S --needed --noconfirm sddm sddm-astronaut-theme qt6-virtualkeyboard \
      || log_warn "One or more SDDM stack packages failed (see above). Continuing with /etc copy if possible."
  else
    "$aur" -S --needed sddm sddm-astronaut-theme qt6-virtualkeyboard \
      || log_warn "One or more SDDM stack packages failed (see above). Continuing with /etc copy if possible."
  fi
  have_sudo
  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  log_step "Copying $REPO_DIR/sddm/ → /etc (sudo; existing files get .bak.$ts)…"
  if [[ -f /etc/sddm.conf ]]; then
    sudo cp -a /etc/sddm.conf "/etc/sddm.conf.bak.$ts"
  fi
  sudo install -Dm644 "$REPO_DIR/sddm/sddm.conf" /etc/sddm.conf
  sudo install -d /etc/sddm.conf.d
  local snippet bn
  shopt -s nullglob
  for snippet in "$REPO_DIR"/sddm/sddm.conf.d/*.conf; do
    bn="$(basename "$snippet")"
    if [[ -f "/etc/sddm.conf.d/$bn" ]]; then
      sudo cp -a "/etc/sddm.conf.d/$bn" "/etc/sddm.conf.d/${bn}.bak.$ts"
    fi
    sudo install -Dm644 "$snippet" "/etc/sddm.conf.d/$bn"
  done
  shopt -u nullglob
  if sudo systemctl enable sddm 2>/dev/null; then
    log_info "systemd: sddm.service enabled. Reboot or disable another display manager to use SDDM."
  else
    log_warn "Could not enable sddm.service (run: sudo systemctl enable sddm)."
  fi
}

install_optional_features() {
  local aur="$1"
  shift
  local ids=("$@")
  local id
  ((${#ids[@]})) || return 0
  log_step "Applying selected optional features…"
  for id in "${ids[@]}"; do
    case "$id" in
      sddm-stack) install_feature_sddm_stack "$aur" ;;
      *) log_warn "Unknown optional feature «$id» — skipped." ;;
    esac
  done
}

backup_config_path() {
  local target="$1"
  if [[ -e "$target" ]]; then
    local bak="${target}.bak.$(date +%Y%m%d%H%M%S)"
    log_info "Existing path moved aside: $target → $bak"
    mv "$target" "$bak"
  fi
}

deploy_configs() {
  log_step "Deploying dotfiles to $CONFIG_DIR …"
  mkdir -p "$CONFIG_DIR"

  local d missing=0
  for d in hypr kitty fastfetch btop fish noctalia; do
    if [[ ! -d "$REPO_DIR/$d" ]]; then
      log_err "Missing repository directory: $REPO_DIR/$d"
      missing=1
    fi
  done
  if [[ ! -f "$REPO_DIR/starship.toml" ]]; then
    log_err "Missing repository file: $REPO_DIR/starship.toml"
    missing=1
  fi
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi

  for d in hypr kitty fastfetch btop fish noctalia; do
    backup_config_path "$CONFIG_DIR/$d"
    cp -a "$REPO_DIR/$d" "$CONFIG_DIR/"
  done

  backup_config_path "$CONFIG_DIR/starship.toml"
  cp -a "$REPO_DIR/starship.toml" "$CONFIG_DIR/"

  fixup_deployed_paths
  fixup_fish_cachyos_line
  log_info "Configuration files installed (with local path / Fish fixups applied under $CONFIG_DIR only)."
}

main() {
  log_step "Hyprland + Noctalia installer"
  require_not_root
  require_arch_like

  maybe_setup_chaotic_aur

  local aur
  aur="$(ensure_aur_helper)"

  echo
  if [[ "$ASSUME_YES" -eq 1 ]] || prompt_yn "Run a full system upgrade (${aur} -Syu) before installing packages?" "y"; then
    log_step "Updating system…"
    if [[ "$ASSUME_YES" -eq 1 ]]; then
      "$aur" -Syu --noconfirm
    else
      "$aur" -Syu
    fi
  else
    log_info "Skipping full system upgrade."
  fi

  log_step "Installing core packages…"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    "$aur" -S --needed --noconfirm "${PACKAGES_CORE[@]}"
  else
    "$aur" -S --needed "${PACKAGES_CORE[@]}"
  fi

  local optional_list=()
  echo
  log_step "Optional packages (not required for a working Hyprland + Noctalia stack)"
  gather_optional_install_list optional_list
  install_optional_packages "$aur" "${optional_list[@]}"

  local optional_features=()
  echo
  log_step "Optional features (packages + system paths such as /etc)"
  gather_optional_feature_list optional_features
  install_optional_features "$aur" "${optional_features[@]}"

  echo
  if [[ "$ASSUME_YES" -eq 1 ]] || prompt_yn "Copy repository configs into ~/.config (existing dirs are renamed to *.bak.TIMESTAMP)?" "y"; then
    deploy_configs
  else
    log_warn "Skipped config copy. Your packages are installed but configs were not deployed."
  fi

  echo
  log_info "Done. Log out, pick Hyprland at the display manager, or start Hyprland from a TTY per your setup."
  log_info "Per-machine: edit ~/.config/hypr/monitors.conf (e.g. with nwg-displays) if displays differ from your main PC."
}

main "$@"
