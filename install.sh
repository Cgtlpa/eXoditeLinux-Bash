#!/usr/bin/env bash

set -e

DISTRO_NAME="eXodite"
DISTRO_NAME_LOWER="exodite"
DISTRO_ID="exodite"
VERSION="2.0.0

RESET="\e[0m"
RED="\e[31m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
CYAN="\e[1;36m"
PURPLE="\e[1;35m"
NEON_PINK="\e[38;2;255;105;180m"
WHITE="\e[1;37m"
BOLD="\e[1m"

GPU_NVIDIA="NVIDIA proprietary"
GPU_NVIDIA_580="NVIDIA 580xx AUR"
GPU_OPENSRC="Open Source Intel/AMD"
GPU_NONE="None"

CFG_DISK=""
CFG_DISK_SIZE_BYTES=0
CFG_PART_LAYOUT=""
CFG_ROOT_SIZE_GB=30
CFG_KERNEL=""
CFG_GPU=""
CFG_DESKTOP=""
CFG_HOSTNAME=""
CFG_USERNAME=""
CFG_PASSWORD=""
CFG_ROOT_PASS=""
CFG_TIMEZONE=""
CFG_KEYMAP=""
CFG_LOCALE=""
CFG_INSTALL_YAY=""

cleanup() {
    umount -R /mnt 2>/dev/null || true
}

trap_exit() {
    echo -e "${RED}\n[!] Interrupted${RESET}"
    cleanup
    exit 1
}
trap trap_exit SIGINT SIGTERM

spinner() {
    local msg="$1"
    shift
    echo -e -n "${CYAN}[*] ${msg}... ${RESET}"
    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}OK${RESET}"
        return 0
    else
        echo -e "${RED}FAILED${RESET}"
        return 1
    fi
}

prompt() {
    local msg="$1"
    local def="$2"
    local mask="$3"
    local var_name="$4"
    local input

    if [[ -n "$def" ]]; then
        echo -e -n "${YELLOW}? ${RESET}${msg} [${WHITE}${def}${RESET}]: "
    else
        echo -e -n "${YELLOW}? ${RESET}${msg}: "
    fi

    if [[ "$mask" == "true" ]]; then
        read -rs input
        echo
    else
        read -r input
    fi

    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    [[ -z "$input" ]] && input="$def"
    eval "$var_name=\"\$input\""
}

menu_select() {
    local title="$1"
    local var_name="$2"
    shift 2
    local options=("$@")

    echo -e "\n${PURPLE}  ${title}${RESET}\n"
    for i in "${!options[@]}"; do
        echo -e "  ${NEON_PINK}$((i + 1)).${RESET} ${options[$i]}"
    done
    echo

    local choice
    while true; do
        prompt "Select [1-${#options[@]}]" "" "false" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            eval "$var_name=\"\${options[$((choice - 1))]}\""
            break
        fi
        echo -e "${RED}  Invalid${RESET}"
    done
}

print_welcome() {
    clear
    echo -e "${NEON_PINK}${BOLD}"
    cat << "EOF"
 ███████╗██╗  ██╗ ██████╗ ██████╗ ██╗████████╗███████╗
 ██╔════╝╚██╗██╔╝██╔═══██╗██╔══██╗██║╚══██╔══╝██╔════╝
 █████╗   ╚███╔╝ ██║   ██║██║  ██║██║   ██║   █████╗  
 ██╔══╝   ██╔██╗ ██║   ██║██║  ██║██║   ██║   ██╔══╝  
 ███████╗██╔╝ ██╗╚██████╔╝██████╔╝██║   ██║   ███████╗
 ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝   ╚═╝   ╚══════╝
EOF
    echo -e "${RESET}"
    echo -e "${WHITE}${BOLD} ${DISTRO_NAME} v${VERSION}${RESET}\n"
}

setup_network() {
    systemctl start NetworkManager >/dev/null 2>&1 || true
    if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        echo -e "${RED}[!] No network${RESET}"
        local ans
        prompt "Open nmtui? Y/n" "y" "false" ans
        [[ "${ans,,}" == "y" ]] && nmtui
    else
        echo -e "${GREEN}[✓] Network OK${RESET}"
    fi
}

setup_cachy_live() {
    echo -e "${CYAN}[*] CachyOS repo${RESET}"

    if ! spinner "Adding key ubuntu" pacman-key --recv-keys --keyserver hkps://keyserver.ubuntu.com F1656F40D7482129; then
        spinner "Adding key mailfence" pacman-key --recv-keys --keyserver hkps://keys.mailfence.com F1656F40D7482129 || return 1
    fi

    spinner "Signing key" pacman-key --lsign-key F1656F40D7482129 || return 1

    if ! grep -q '\[cachyos\]' /etc/pacman.conf; then
        printf '\n[cachyos]\nServer = https://mirror.cachyos.org/$repo/$arch\n' >> /etc/pacman.conf
    fi

    spinner "Syncing keyring" pacman -Sy --noconfirm cachyos-keyring
}

validate_timezone() {
    [[ -f "/usr/share/zoneinfo/$1" ]]
}

partition_prefix() {
    local disk="$1"
    if [[ "$disk" == *nvme* || "$disk" == *mmcblk* ]]; then
        echo "${disk}p"
    else
        echo "$disk"
    fi
}

list_parts() {
    local disk="$1"
    local base
    base=$(basename "$disk")
    lsblk -nlo NAME "$disk" 2>/dev/null | sed -e 's/[├─└─]//g' -e 's/ //g' | grep -v "^${base}$" | grep -v "^$" | awk '{print "/dev/"$1}'
}

check_free() {
    local disk="$1"
    local out free_bytes=0
    out=$(sgdisk --print "$disk" 2>/dev/null)

    while IFS= read -r line; do
        if [[ "$line" == *"free space"* ]]; then
            local raw num unit
            raw=$(echo "$line" | grep -o '([0-9.]* [KMGTP]iB)' | tr -d '()')
            num=$(echo "$raw" | awk '{print $1}')
            unit=$(echo "$raw" | awk '{print $2}')
            case "$unit" in
                KiB) free_bytes=$(echo "$num * 1024" | bc | cut -d. -f1) ;;
                MiB) free_bytes=$(echo "$num * 1024 * 1024" | bc | cut -d. -f1) ;;
                GiB) free_bytes=$(echo "$num * 1024 * 1024 * 1024" | bc | cut -d. -f1) ;;
                TiB) free_bytes=$(echo "$num * 1024 * 1024 * 1024 * 1024" | bc | cut -d. -f1) ;;
            esac
        fi
    done <<< "$out"
    echo "${free_bytes:-0}"
}

gather_config() {
    print_welcome

    local keymaps=("us" "de" "uk" "fr" "es" "it" "pt" "ru" "pl" "nl" "colemak")
    menu_select "Keyboard" CFG_KEYMAP "${keymaps[@]}"
    loadkeys "$CFG_KEYMAP" >/dev/null 2>&1 || true

    local default_tz="UTC"
    if [[ -L /etc/localtime ]]; then
        local target
        target=$(readlink /etc/localtime)
        [[ "$target" == /usr/share/zoneinfo/* ]] && default_tz="${target#/usr/share/zoneinfo/}"
    fi
    while true; do
        prompt "Timezone" "$default_tz" "false" CFG_TIMEZONE
        validate_timezone "$CFG_TIMEZONE" && break
        echo -e "${RED}[!] Invalid${RESET}"
    done

    local locales=("en_US.UTF-8" "en_GB.UTF-8" "de_DE.UTF-8" "fr_FR.UTF-8" "es_ES.UTF-8" "it_IT.UTF-8" "pt_PT.UTF-8" "ru_RU.UTF-8")
    menu_select "Locale" CFG_LOCALE "${locales[@]}"

    local disks_found=() disk_options=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name size model path size_bytes
        name=$(echo "$line" | awk '{print $1}')
        [[ "$name" == loop* ]] && continue
        size=$(echo "$line" | awk '{print $2}')
        model=$(echo "$line" | awk '{for(i=3;i<=NF;++i) printf $i" "}')
        path="/dev/$name"
        size_bytes=$(lsblk -b -d -n -o SIZE "$path" 2>/dev/null | tr -d ' ')
        disks_found+=("$path|$size|$model|$size_bytes")
        disk_options+=("$path  ($size $model)")
    done < <(lsblk -d -n -o NAME,SIZE,MODEL)

    if [[ ${#disk_options[@]} -eq 0 ]]; then
        echo -e "${RED}[!] No disks${RESET}"
        exit 1
    fi

    local disk_choice
    menu_select "Disk" disk_choice "${disk_options[@]}"
    local chosen_path
    chosen_path=$(echo "$disk_choice" | awk '{print $1}')

    for d in "${disks_found[@]}"; do
        IFS='|' read -r d_path d_size d_model d_bytes <<< "$d"
        if [[ "$d_path" == "$chosen_path" ]]; then
            CFG_DISK="$d_path"
            CFG_DISK_SIZE_BYTES="$d_bytes"
            break
        fi
    done

    local min_disk_bytes=$((20 * 1024 * 1024 * 1024))
    if (( CFG_DISK_SIZE_BYTES > 0 && CFG_DISK_SIZE_BYTES < min_disk_bytes )); then
        local disk_gib=$(( CFG_DISK_SIZE_BYTES / 1024 / 1024 / 1024 ))
        echo -e "${YELLOW}[!] Disk ${disk_gib}GB < 20GB${RESET}"
        local ans
        prompt "Continue? yes/no" "no" "false" ans
        if [[ "${ans,,}" != "yes" && "${ans,,}" != "y" ]]; then
            echo -e "${CYAN}[*] Aborted${RESET}"
            exit 0
        fi
    fi

    local layouts=("Single" "Separate /home" "Dualboot")
    local layout_choice
    menu_select "Partition layout" layout_choice "${layouts[@]}"

    case "$layout_choice" in
        "Separate /home")
            CFG_PART_LAYOUT="split"
            local def_root=30
            if (( CFG_DISK_SIZE_BYTES > 0 )); then
                local disk_gib=$(( CFG_DISK_SIZE_BYTES / 1024 / 1024 / 1024 ))
                (( disk_gib < 40 )) && def_root=$(( disk_gib / 2 ))
            fi
            while true; do
                prompt "Root size GB" "$def_root" "false" CFG_ROOT_SIZE_GB
                [[ "$CFG_ROOT_SIZE_GB" =~ ^[0-9]+$ ]] && (( CFG_ROOT_SIZE_GB > 0 )) && break
                echo -e "${RED}Invalid${RESET}"
            done
            ;;
        "Dualboot")
            CFG_PART_LAYOUT="dualboot"
            echo -e "${YELLOW}[!] Needs free space${RESET}"
            while true; do
                prompt "Root size GB" "30" "false" CFG_ROOT_SIZE_GB
                [[ "$CFG_ROOT_SIZE_GB" =~ ^[0-9]+$ ]] && (( CFG_ROOT_SIZE_GB > 0 )) && break
                echo -e "${RED}Invalid${RESET}"
            done
            ;;
        *)
            CFG_PART_LAYOUT="single"
            ;;
    esac

    local kernels=("linux" "linux-lts" "linux-zen" "linux-cachyos")
    menu_select "Kernel" CFG_KERNEL "${kernels[@]}"

    local gpus=("$GPU_NVIDIA" "$GPU_NVIDIA_580" "$GPU_OPENSRC" "$GPU_NONE")
    menu_select "GPU driver" CFG_GPU "${gpus[@]}"

    local desktops=("KDE" "XFCE4" "Hyprland" "Sway" "i3" "Qtile" "AwesomeWM" "Cinnamon" "LXDE" "IceWM" "Niri" "None")
    menu_select "Desktop" CFG_DESKTOP "${desktops[@]}"

    local yay_opts=("Yes" "No")
    menu_select "Install Yay?" CFG_INSTALL_YAY "${yay_opts[@]}"

    echo -e "${PURPLE}\n--- Users ---${RESET}"

    while true; do
        prompt "Hostname" "$DISTRO_NAME_LOWER" "false" CFG_HOSTNAME
        [[ "$CFG_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]] && break
        echo -e "${RED}[!] Invalid${RESET}"
    done

    while true; do
        prompt "Username" "user" "false" CFG_USERNAME
        [[ "$CFG_USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
        echo -e "${RED}[!] Invalid${RESET}"
    done

    while true; do
        prompt "User password" "" "true" CFG_PASSWORD
        [[ -z "$CFG_PASSWORD" ]] && { echo -e "${RED}[!] Empty${RESET}"; continue; }
        local confirm
        prompt "Confirm" "" "true" confirm
        [[ "$CFG_PASSWORD" == "$confirm" ]] && break
        echo -e "${RED}[!] No match${RESET}"
    done

    while true; do
        prompt "Root password" "" "true" CFG_ROOT_PASS
        [[ -z "$CFG_ROOT_PASS" ]] && { echo -e "${RED}[!] Empty${RESET}"; continue; }
        local confirm
        prompt "Confirm" "" "true" confirm
        [[ "$CFG_ROOT_PASS" == "$confirm" ]] && break
        echo -e "${RED}[!] No match${RESET}"
    done
}

confirm_install() {
    echo -e "${PURPLE}\n=== Summary ===${RESET}"
    printf "Disk: %s\n" "$CFG_DISK"
    printf "Layout: %s\n" "$CFG_PART_LAYOUT"
    [[ "$CFG_PART_LAYOUT" == "split" || "$CFG_PART_LAYOUT" == "dualboot" ]] && printf "Root: %d GB\n" "$CFG_ROOT_SIZE_GB"
    printf "Kernel: %s\n" "$CFG_KERNEL"
    printf "GPU: %s\n" "$CFG_GPU"
    printf "Desktop: %s\n" "$CFG_DESKTOP"
    printf "Yay: %s\n" "$CFG_INSTALL_YAY"
    printf "Hostname: %s\n" "$CFG_HOSTNAME"
    printf "User: %s\n" "$CFG_USERNAME"
    printf "Timezone: %s\n" "$CFG_TIMEZONE"
    printf "Locale: %s\n" "$CFG_LOCALE"
    printf "Keymap: %s\n" "$CFG_KEYMAP"

    local ans
    prompt "Proceed? yes/no" "no" "false" ans
    [[ "${ans,,}" == "yes" || "${ans,,}" == "y" ]]
}

partition_disk() {
    [[ "$CFG_PART_LAYOUT" == "dualboot" ]] && { partition_dualboot; return; }

    local disk="$CFG_DISK"
    spinner "Wiping table" sgdisk -Z "$disk"

    if [[ "$CFG_PART_LAYOUT" == "split" ]]; then
        spinner "EFI 1GB" sgdisk -n 1:0:+1G -t 1:ef00 "$disk"
        spinner "Root ${CFG_ROOT_SIZE_GB}GB" sgdisk -n "2:0:+${CFG_ROOT_SIZE_GB}G" -t 2:8300 "$disk"
        spinner "Home rest" sgdisk -n 3:0:0 -t 3:8300 "$disk"
    else
        spinner "EFI 1GB" sgdisk -n 1:0:+1G -t 1:ef00 "$disk"
        spinner "Root rest" sgdisk -n 2:0:0 -t 2:8300 "$disk"
    fi

    udevadm settle --timeout=10
    local p efi root
    p=$(partition_prefix "$disk")
    efi="${p}1"
    root="${p}2"

    spinner "Format EFI" mkfs.fat -F32 "$efi"
    spinner "Format root" mkfs.ext4 -F "$root"
    spinner "Mount root" mount "$root" /mnt
    mkdir -p /mnt/boot/efi
    spinner "Mount EFI" mount "$efi" /mnt/boot/efi

    if [[ "$CFG_PART_LAYOUT" == "split" ]]; then
        local home="${p}3"
        spinner "Format home" mkfs.ext4 -F "$home"
        mkdir -p /mnt/home
        spinner "Mount home" mount "$home" /mnt/home
    fi
}

partition_dualboot() {
    local disk="$CFG_DISK"
    echo -e "${CYAN}[*] Dualboot mode${RESET}"

    local parts_before=()
    mapfile -t parts_before < <(list_parts "$disk")

    local efi_device="" has_efi=0
    while IFS= read -r line; do
        local name ptype
        name=$(echo "$line" | awk '{print $1}')
        ptype=$(echo "$line" | awk '{print $2}')
        if [[ "$ptype" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
            efi_device="/dev/$name"
            has_efi=1
            break
        fi
    done < <(lsblk -nlo NAME,PARTTYPE "$disk")

    if [[ $has_efi -eq 1 ]]; then
        echo -e "[*] Using existing EFI: $efi_device"
    else
        echo -e "[*] Creating EFI partition"
        local efi_need_bytes=$(( 512 * 1024 * 1024 ))
        local free_bytes
        free_bytes=$(check_free "$disk")

        if (( free_bytes > 0 && free_bytes < efi_need_bytes )); then
            echo -e "${RED}[!] Not enough space for EFI${RESET}"
            return 1
        fi

        spinner "Create EFI 512MB" sgdisk -n 0:0:+512M -t 0:ef00 "$disk"
        partprobe "$disk" >/dev/null 2>&1 || true
        udevadm settle --timeout=10

        local parts_after=()
        mapfile -t parts_after < <(list_parts "$disk")
        for p in "${parts_after[@]}"; do
            local found=0
            for b in "${parts_before[@]}"; do [[ "$p" == "$b" ]] && found=1 && break; done
            if [[ $found -eq 0 ]]; then efi_device="$p"; break; fi
        done
        parts_before=("${parts_after[@]}")
        spinner "Format EFI" mkfs.fat -F32 "$efi_device"
    fi

    [[ -z "$efi_device" ]] && { echo -e "${RED}[!] No EFI partition${RESET}"; return 1; }

    local need_bytes=$(( CFG_ROOT_SIZE_GB * 1024 * 1024 * 1024 ))
    local free_bytes
    free_bytes=$(check_free "$disk")
    if (( free_bytes > 0 && free_bytes < need_bytes )); then
        echo -e "${RED}[!] Need ${CFG_ROOT_SIZE_GB}GB, have $(( free_bytes / 1024 / 1024 / 1024 ))GB${RESET}"
        return 1
    fi

    spinner "Create root ${CFG_ROOT_SIZE_GB}GB" sgdisk -n "0:0:+${CFG_ROOT_SIZE_GB}G" -t 0:8300 "$disk"
    partprobe "$disk" >/dev/null 2>&1 || true
    udevadm settle --timeout=10

    local root_device="" parts_after=()
    mapfile -t parts_after < <(list_parts "$disk")
    for p in "${parts_after[@]}"; do
        local found=0
        for b in "${parts_before[@]}"; do [[ "$p" == "$b" ]] && found=1 && break; done
        [[ $found -eq 0 ]] && root_device="$p"
    done

    [[ -z "$root_device" ]] && { echo -e "${RED}[!] No root partition${RESET}"; return 1; }

    spinner "Format root" mkfs.ext4 -F "$root_device"
    spinner "Mount root" mount "$root_device" /mnt
    mkdir -p /mnt/boot/efi
    spinner "Mount EFI" mount "$efi_device" /mnt/boot/efi

    echo -e "${GREEN}[✓] Dualboot ready${RESET}"
}

install_base() {
    local pkgs=("base" "base-devel" "linux-firmware" "networkmanager" "grub" "efibootmgr" "nano" "vim" "git" "fastfetch")

    if [[ "$CFG_KERNEL" != "linux-cachyos" ]]; then
        pkgs+=("$CFG_KERNEL" "${CFG_KERNEL}-headers")
    fi

    case "$CFG_GPU" in
        "$GPU_NVIDIA")
            if [[ "$CFG_KERNEL" == "linux" || "$CFG_KERNEL" == "linux-lts" ]]; then
                pkgs+=("nvidia" "nvidia-utils" "nvidia-settings")
            else
                pkgs+=("nvidia-dkms" "nvidia-utils" "nvidia-settings")
            fi
            ;;
        "$GPU_OPENSRC")
            pkgs+=("mesa" "vulkan-radeon" "vulkan-intel" "libva-mesa-driver")
            ;;
    esac

    case "$CFG_DESKTOP" in
        "KDE") pkgs+=("plasma" "sddm" "konsole" "dolphin" "ark") ;;
        "XFCE4") pkgs+=("xfce4" "xfce4-goodies" "lightdm" "lightdm-gtk-greeter") ;;
        "Hyprland") pkgs+=("hyprland" "kitty" "waybar" "wofi" "xdg-desktop-portal-hyprland" "sddm") ;;
        "Sway") pkgs+=("sway" "swaylock" "swayidle" "waybar" "wofi" "foot" "xdg-desktop-portal-wlr" "sddm") ;;
        "i3") pkgs+=("i3-wm" "i3status" "i3lock" "dmenu" "xorg-server" "xorg-xinit" "alacritty" "lightdm" "lightdm-gtk-greeter") ;;
        "Qtile") pkgs+=("qtile" "alacritty" "xorg-server" "xorg-xinit" "lightdm" "lightdm-gtk-greeter") ;;
        "AwesomeWM") pkgs+=("awesome" "alacritty" "xorg-server" "xorg-xinit" "lightdm" "lightdm-gtk-greeter") ;;
        "Cinnamon") pkgs+=("cinnamon" "gnome-terminal" "xorg-server" "lightdm" "lightdm-gtk-greeter") ;;
        "LXDE") pkgs+=("lxde" "lxdm" "xorg-server") ;;
        "IceWM") pkgs+=("icewm" "icewm-themes" "xorg-server" "xorg-xinit" "lightdm" "lightdm-gtk-greeter") ;;
        "Niri") pkgs+=("niri" "foot" "waybar" "wofi" "sddm") ;;
    esac

    echo -e "${CYAN}[*] Installing base system${RESET}"
    pacstrap /mnt "${pkgs[@]}"
}

configure_system() {
    genfstab -U /mnt > /mnt/etc/fstab

    local logo_ansi
    logo_ansi=$(printf '\e[1;35m ███████╗██╗  ██╗ ██████╗ ██████╗ ██╗████████╗███████╗\n ██╔════╝╚██╗██╔╝██╔═══██╗██╔══██╗██║╚══██╔══╝██╔════╝\n █████╗   ╚███╔╝ ██║   ██║██║  ██║██║   ██║   █████╗  \n ██╔══╝   ██╔██╗ ██║   ██║██║  ██║██║   ██║   ██╔══╝  \n ███████╗██╔╝ ██╗╚██████╔╝██████╔╝██║   ██║   ███████╗\n ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝   ╚═╝   ╚══════╝\e[0m')
    local conf_json='{"logo":{"source":"/etc/fastfetch/logo.txt"},"modules":["title","os","kernel","uptime","shell","de","cpu","memory"]}'

    mkdir -p /mnt/etc/fastfetch
    printf '%b\n' "$logo_ansi" > /mnt/etc/fastfetch/logo.txt
    echo "$conf_json" > /mnt/etc/fastfetch/config.jsonc

    cat > /mnt/setup.sh << EOF
#!/bin/bash
set -e
trap 'rm -f /passwd.tmp' EXIT

GPU_DRIVER="${CFG_GPU}"
INSTALL_YAY="${CFG_INSTALL_YAY}"

ln -sf /usr/share/zoneinfo/${CFG_TIMEZONE} /etc/localtime
hwclock --systohc

echo "${CFG_LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${CFG_LOCALE}" > /etc/locale.conf
echo "LC_ALL=${CFG_LOCALE}" >> /etc/locale.conf
echo "${CFG_HOSTNAME}" > /etc/hostname
echo "KEYMAP=${CFG_KEYMAP}" > /etc/vconsole.conf

printf "127.0.0.1 localhost\n::1 localhost\n127.0.1.1 ${CFG_HOSTNAME}.localdomain ${CFG_HOSTNAME}\n" > /etc/hosts

printf 'NAME="${DISTRO_NAME} Linux"\nID=${DISTRO_ID}\nID_LIKE=arch\nPRETTY_NAME="${DISTRO_NAME} Linux"\n' > /etc/os-release

sed -i 's/GRUB_DISTRIBUTOR="Arch"/GRUB_DISTRIBUTOR="${DISTRO_NAME}"/' /etc/default/grub

if [ "\$GPU_DRIVER" = "${GPU_NVIDIA}" ] || [ "\$GPU_DRIVER" = "${GPU_NVIDIA_580}" ]; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& nvidia-drm.modeset=1/' /etc/default/grub
    sed -i 's/MODULES=()/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
fi

if [ "${CFG_KERNEL}" = "linux-cachyos" ]; then
    if ! grep -q '\[cachyos\]' /etc/pacman.conf; then
        printf '\n[cachyos]\nServer = https://mirror.cachyos.org/\$repo/\$arch\n' >> /etc/pacman.conf
    fi
    pacman-key --recv-keys --keyserver hkps://keyserver.ubuntu.com F1656F40D7482129 || \
        pacman-key --recv-keys --keyserver hkps://keys.mailfence.com F1656F40D7482129
    pacman-key --lsign-key F1656F40D7482129
    pacman -Sy --noconfirm cachyos-keyring cachyos-mirrorlist
    pacman -S --noconfirm linux-cachyos linux-cachyos-headers
fi

useradd -m -G wheel -s /bin/bash "${CFG_USERNAME}"
echo "root:${CFG_ROOT_PASS}" | chpasswd
echo "${CFG_USERNAME}:${CFG_PASSWORD}" | chpasswd

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

YAY_DONE=0
if [ "\$GPU_DRIVER" = "${GPU_NVIDIA_580}" ]; then
    useradd -m -s /bin/bash tempbuilder || true
    usermod -aG wheel tempbuilder
    echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/99-yay-build
    chmod 440 /etc/sudoers.d/99-yay-build
    su - tempbuilder -c '
        export HOME=/home/tempbuilder
        cd "\$HOME"
        git clone https://aur.archlinux.org/yay-bin.git
        cd yay-bin
        makepkg -si --noconfirm
        cd .. && rm -rf yay-bin
    '
    rm -f /etc/sudoers.d/99-yay-build
    userdel -r tempbuilder 2>/dev/null || true
    yay -S --noconfirm nvidia-580xx-dkms nvidia-580xx-utils nvidia-580xx-settings
    YAY_DONE=1
fi

sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

ROOT_UUID=\$(findmnt -n -o UUID /)
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"root=UUID=\$ROOT_UUID |" /etc/default/grub

if [ -d /sys/firmware/efi ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="${DISTRO_NAME}"
else
    DISK=\$(lsblk -no PKNAME "\$(findmnt -n -o SOURCE /)" | head -1)
    grub-install --target=i386-pc "/dev/\$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager

case "${CFG_DESKTOP}" in
    "KDE"|"Hyprland"|"Sway"|"Qtile"|"Niri") systemctl enable sddm ;;
    "XFCE4"|"i3"|"AwesomeWM"|"Cinnamon"|"IceWM") systemctl enable lightdm ;;
    "LXDE") systemctl enable lxdm ;;
esac

if [ "${CFG_DESKTOP}" = "Niri" ]; then
    mkdir -p /etc/sddm.conf.d
    printf "[General]\nDisplayServer=wayland\nGreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell\n" > /etc/sddm.conf.d/wayland.conf
fi

dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap defaults 0 0' >> /etc/fstab

echo 'fastfetch' >> /home/${CFG_USERNAME}/.bashrc
echo 'fastfetch' >> /root/.bashrc

if [ "\$INSTALL_YAY" = "Yes" ] && [ "\$YAY_DONE" -eq 0 ]; then
    useradd -m -s /bin/bash tempbuilder || true
    usermod -
