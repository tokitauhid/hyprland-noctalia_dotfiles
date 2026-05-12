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

  -y, --yes, --assume-yes   Non-interactive: defaults (no Chaotic AUR, no
                            optional desktop apps, run system update, skip
                            AUR helper install if none found — install fails).

  Chaotic AUR / AUR helper prompts are skipped when using -y unless you
  pre-set: CHAOTIC_AUR=1  AUR_HELPER=paru|yay  (helper must exist in PATH).

Environment:
  CHAOTIC_AUR=0|1     Add Chaotic AUR repo (requires sudo).
  AUR_HELPER=paru|yay Force which helper to use (must be in PATH).
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
    log_err "Non-interactive mode: install paru or yay, or set AUR_HELPER=paru|yay and ensure it is in PATH."
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
  noctalia-shell sddm-theme-noctalia-git nwg-displays
  bash fish starship bat btop eza fastfetch fd fzf git ripgrep
  playerctl pamixer satty uwsm libnotify jq polkit-gnome
  ttf-adwaita ttf-jetbrains-mono-nerd
)

PACKAGES_OPTIONAL=(
  steam discord code helium-browser
)

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
  log_info "Configuration files installed."
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
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log_info "Skipping optional packages (steam, discord, code, helium-browser) in non-interactive mode."
  else
    echo
    log_info "Optional packages (from your previous script): ${PACKAGES_OPTIONAL[*]}"
    if prompt_yn "Install these optional packages?" "n"; then
      optional_list=("${PACKAGES_OPTIONAL[@]}")
    fi
  fi
  if ((${#optional_list[@]})); then
    log_step "Installing optional packages…"
    "$aur" -S --needed "${optional_list[@]}"
  fi

  echo
  if [[ "$ASSUME_YES" -eq 1 ]] || prompt_yn "Copy repository configs into ~/.config (existing dirs are renamed to *.bak.TIMESTAMP)?" "y"; then
    deploy_configs
  else
    log_warn "Skipped config copy. Your packages are installed but configs were not deployed."
  fi

  echo
  log_info "Done. Log out, pick Hyprland at the display manager, or start Hyprland from a TTY per your setup."
}

main "$@"
