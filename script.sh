#!/bin/bash
#
# MikroTik CHR installer for VPS (written for Nazwa.pl, Ubuntu 16.04+)
# Installs the newest RouterOS v7 *stable* CHR image over the VPS disk.
#
# One-line install:
#   wget -qO- https://raw.githubusercontent.com/iksiu6/Mikrotik-CHR-VPS/main/script.sh | sudo bash
#
# Optional variables (put them before "bash"):
#   CHR_PASSWORD=haslo   password for user "root" (random one is generated if empty)
#   CHR_USER=root        login name (default: root)
#   CHR_VERSION=7.24.4   force a specific version instead of newest stable
#   CHR_CHANNEL=stable   stable | long-term | testing
#   CHR_IFACE=enp1s0     network interface (auto-detected)
#   CHR_DISK=/dev/vda    target disk (auto-detected)
#   CHR_YES=1            don't wait 10 s before wiping the disk
#
# Example:
#   wget -qO- https://raw.githubusercontent.com/iksiu6/Mikrotik-CHR-VPS/main/script.sh | sudo CHR_PASSWORD='MojeHaslo' bash
#
# WARNING: this ERASES the whole disk of the VPS!

# Everything is inside main() so bash reads the whole script before running it
# (important when the script is piped from wget/curl).
main() {
    set -euo pipefail

    CHR_USER="${CHR_USER:-root}"
    CHR_CHANNEL="${CHR_CHANNEL:-stable}"

    die() { echo "ERROR: $*" >&2; exit 1; }

    [ "$(id -u)" -eq 0 ] || die "run as root (sudo bash)"
    for c in ip awk dd mount umount lsblk; do
        command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
    done
    command -v unzip >/dev/null 2>&1 || command -v gunzip >/dev/null 2>&1 || die "unzip or gunzip is required"

    fetch() { # fetch URL [output]
        if command -v wget >/dev/null 2>&1; then
            if [ -n "${2:-}" ]; then wget -q --show-progress -O "$2" "$1" || wget -O "$2" "$1"
            else wget -qO- "$1"; fi
        elif command -v curl >/dev/null 2>&1; then
            if [ -n "${2:-}" ]; then curl -fL -o "$2" "$1"; else curl -fsSL "$1"; fi
        else
            die "wget or curl is required"
        fi
    }

    # --- 1. Newest version -------------------------------------------------
    if [ -z "${CHR_VERSION:-}" ]; then
        case "$CHR_CHANNEL" in
            stable)    f=NEWESTa7.stable ;;
            long-term) f=NEWESTa7.long-term ;;
            testing)   f=NEWESTa7.testing ;;
            *) die "unknown CHR_CHANNEL: $CHR_CHANNEL" ;;
        esac
        CHR_VERSION="$(fetch "https://upgrade.mikrotik.com/routeros/$f" | awk '{print $1}')"
    fi
    echo "$CHR_VERSION" | grep -Eq '^[0-9]+\.[0-9]+' || die "could not determine RouterOS version (got: '$CHR_VERSION')"
    echo ">>> RouterOS CHR version: $CHR_VERSION ($CHR_CHANNEL)"

    # --- 2. Network (auto-detect) ------------------------------------------
    CHR_IFACE="${CHR_IFACE:-$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"
    [ -n "$CHR_IFACE" ] || die "could not detect network interface, set CHR_IFACE"
    ADDRESS="$(ip -4 addr show dev "$CHR_IFACE" scope global | awk '/inet /{print $2; exit}')"
    GATEWAY="$(ip -4 route show default | awk '{print $3; exit}')"
    [ -n "$ADDRESS" ] || die "no IPv4 address on $CHR_IFACE"
    [ -n "$GATEWAY" ] || die "no default gateway"
    echo ">>> Interface: $CHR_IFACE  Address: $ADDRESS  Gateway: $GATEWAY"

    # --- 3. Target disk (auto-detect) --------------------------------------
    if [ -z "${CHR_DISK:-}" ]; then
        ROOTDEV="$(findmnt -n -o SOURCE / 2>/dev/null || awk '$2=="/"{print $1}' /proc/mounts | tail -n1)"
        # walk up from the root filesystem (partition / LVM / RAID) to the physical disk
        PK="$(lsblk -rnso NAME,TYPE "$ROOTDEV" 2>/dev/null | awk '$2=="disk"{print $1; exit}' || true)"
        if [ -n "$PK" ]; then
            CHR_DISK="/dev/$PK"
        else
            for d in /dev/vda /dev/sda /dev/xvda /dev/nvme0n1; do [ -b "$d" ] && { CHR_DISK="$d"; break; }; done
        fi
    fi
    [ -b "${CHR_DISK:-}" ] || die "could not detect target disk, set CHR_DISK"
    echo ">>> Target disk: $CHR_DISK"

    # --- 4. Password -------------------------------------------------------
    if [ -z "${CHR_PASSWORD:-}" ]; then
        CHR_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true)"
        GENERATED=1
    fi

    # --- 5. Download image (into RAM so dd doesn't read a file it overwrites)
    # The image MUST be in RAM: a file on the disk would be overwritten while dd reads it.
    WORK=/dev/shm/chr
    if [ ! -d /dev/shm ] || [ "$(df -Pm /dev/shm | awk 'NR==2{print $4}')" -lt 300 ]; then
        mkdir -p /mnt/chr-ram && mount -t tmpfs -o size=320m tmpfs /mnt/chr-ram \
            || die "cannot create RAM disk for the image"
        WORK=/mnt/chr-ram/chr
    fi
    MEM_AVAIL="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)"
    [ -z "$MEM_AVAIL" ] || [ "$MEM_AVAIL" -ge 300 ] \
        || die "not enough free RAM (${MEM_AVAIL} MB, need ~300 MB) - stop other services first"
    rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

    URL="https://download.mikrotik.com/routeros/$CHR_VERSION/chr-$CHR_VERSION.img.zip"
    echo ">>> Downloading $URL"
    fetch "$URL" chr.img.zip || die "download failed"
    if command -v unzip >/dev/null 2>&1; then unzip -p chr.img.zip > chr.img
    else gunzip -c chr.img.zip > chr.img; fi
    rm -f chr.img.zip
    [ -s chr.img ] || die "image is empty"

    # --- 6. Write autorun.scr into the image -------------------------------
    # v7 images have 2 partitions, RouterOS data is on the 2nd one.
    START="$(fdisk -l chr.img 2>/dev/null | awk '/^chr\.img2/{ s=$2; if(s=="*") s=$3; print s; exit}' || true)"
    [ -n "$START" ] || START="$(sfdisk -d chr.img 2>/dev/null | awk -F'[=,]' '/^chr\.img2/{gsub(/ /,"",$2); print $2; exit}' || true)"
    if [ -n "$START" ]; then OFFSET=$((START * 512)); else OFFSET=33571840; fi
    MNT="$WORK/mnt"; mkdir -p "$MNT"
    mount -o loop,offset="$OFFSET" chr.img "$MNT" || mount -o loop,offset=512 chr.img "$MNT" \
        || die "cannot mount CHR image"
    mkdir -p "$MNT/rw"
    cat > "$MNT/rw/autorun.scr" <<EOF
/ip address add address=$ADDRESS interface=[/interface ethernet find where name=ether1]
/ip route add gateway=$GATEWAY
/ip dns set servers=1.1.1.1,8.8.8.8
/ip service disable telnet,ftp,api,api-ssl
/user set 0 name=$CHR_USER password="$CHR_PASSWORD"
EOF
    umount "$MNT"

    # --- 7. Summary + last chance -----------------------------------------
    echo
    echo "=========================================================="
    echo "  RouterOS CHR $CHR_VERSION will be written to $CHR_DISK"
    echo "  After reboot log in with WinBox / SSH:"
    echo "    address : ${ADDRESS%/*}"
    echo "    login   : $CHR_USER"
    echo "    password: $CHR_PASSWORD"
    [ -n "${GENERATED:-}" ] && echo "  (password was generated - WRITE IT DOWN NOW!)"
    echo "=========================================================="
    if [ -z "${CHR_YES:-}" ]; then
        echo "Wiping $CHR_DISK in 10 s... press Ctrl+C to abort"
        sleep 10
    fi

    # --- 8. Write and reboot ----------------------------------------------
    # While dd overwrites the disk, NOTHING may be loaded from that disk any
    # more (on a small VPS the kernel evicts program pages and re-reads them
    # from the now-overwritten disk -> segfault / "Bad message").
    # So copy bash + dd + their libraries into RAM and run the last stage from there.
    RAMBIN="$WORK/bin"; mkdir -p "$RAMBIN"
    BASH_BIN="$(command -v bash)"; DD_BIN="$(command -v dd)"
    cp "$BASH_BIN" "$RAMBIN/bash"; cp "$DD_BIN" "$RAMBIN/dd"
    LOADER=""
    for f in $( (ldd "$BASH_BIN"; ldd "$DD_BIN") | awk '$2=="=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' | sort -u); do
        cp -L "$f" "$RAMBIN/"
        case "$f" in */ld-linux*|*/ld64*|*/ld-*.so*) LOADER="$RAMBIN/$(basename "$f")" ;; esac
    done
    [ -n "$LOADER" ] || die "could not find the dynamic loader"
    RUN=("$LOADER" --library-path "$RAMBIN")
    "${RUN[@]}" "$RAMBIN/dd" --version >/dev/null 2>&1 || die "cannot run dd from RAM"

    swapoff -a 2>/dev/null || true      # RAM pages must not be swapped to the disk
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true   # free RAM before the last stage
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    sync

    # Last stage: only builtins + dd from RAM. Reboots even if dd fails.
    exec "${RUN[@]}" "$RAMBIN/bash" --norc --noprofile -c '
        LD="$1"; BIN="$2"; IMG="$3"; DISK="$4"
        echo u > /proc/sysrq-trigger                 # remount filesystems read-only
        echo ">>> Writing image to $DISK ..."
        if "$LD" --library-path "$BIN" "$BIN/dd" if="$IMG" of="$DISK" bs=1M conv=fsync; then
            echo ">>> Image written"
        else
            echo "!!! dd failed - image may be incomplete"
        fi
        echo s > /proc/sysrq-trigger
        t=$SECONDS; while [ $((SECONDS - t)) -lt 5 ]; do :; done
        echo ">>> Reboot"
        echo b > /proc/sysrq-trigger
    ' _ "$LOADER" "$RAMBIN" "$WORK/chr.img" "$CHR_DISK"
}

main "$@"
