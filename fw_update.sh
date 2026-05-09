#!/usr/bin/env bash
#
# Cartographer3D firmware update helper - guides users through updating probe firmware.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Inner width between | borders (wider reduces overlap on long paths and messages)
readonly _BOX_INNER=90
readonly _API_BASE="https://api.cartographer3d.com/q/device_name"
readonly _API_UUID_BASE="https://api.cartographer3d.com/q/uuid"
readonly _FWU_REPORT_BASE="https://api.cartographer3d.com/report"

# Populated by gather_cartographer_identity()
CARTO_SERIAL=""
CARTO_CANBUS=""
# Which [mcu …] block had canbus_uuid: "cartographer" | "scanner" (empty if unknown)
CARTO_MCU_SECTION=""
# From Moonraker object query when on CAN (e.g. 1000000)
FWU_CANBUS_FREQUENCY=""
DETECTED_PROBE="unknown"
# When V4: api_usb | api_uuid | moonraker
FWU_V4_VIA=""
# Connection: CAN | USB | unknown (from config; CAN takes precedence over serial)
FWU_PROTOCOL="unknown"
# Normalized CAN baud: 250000 | 500000 | 1000000 | empty for USB
FWU_CAN_SPEED=""
# yes if CAN baud was defaulted because Moonraker did not report it
FWU_CAN_SPEED_ASSUMED="no"
# From firmware_list.csv + lookup_firmware_recommendation()
FWU_REC_NO_MATCH="1"
FWU_REC_VERSION=""
FWU_REC_HAS_FULL="0"
FWU_REC_HAS_LITE="0"
FWU_REC_FULL_PATH=""
FWU_REC_FULL_FILE=""
FWU_REC_LITE_PATH=""
FWU_REC_LITE_FILE=""
# User selection: full | lite
FWU_FW_SELECTED_KIND=""
FWU_FW_SELECTED_PATH=""
FWU_FW_SELECTED_FILE=""
# Linux CAN net device for flashing (CAN probes only; default can0)
FWU_CAN_INTERFACE="can0"
# Distinct firmware_version values from CSV for this probe/link (newline-separated, newest first)
FWU_VERSIONS_AVAILABLE=""
FWU_VER_LATEST=""
# User-chosen firmware_version string (e.g. 6.0.0)
FWU_FW_VERSION_CHOSEN=""
# Semver parsed from Moonraker mcu object mcu_version (e.g. 6.1.0 from "CARTOGRAPHER V4 6.1.0")
CURRENTFW=""
# Diagnostics for probe screen (yes/no and paths)
FWU_KLIPPY_LOG_FOUND=""
FWU_KLIPPY_LOG_PATH=""
FWU_MCU_SECTION_FOUND=""
FWU_MCU_SECTION_FILES=""
# ~/klippy-env pip: full suffix e.g. 1.5.3b2.dev1 (detect_cartographer_plugin_version)
FWU_PLUGIN_VERSION_RAW=""
# Leading X.Y.Z parsed from RAW for display/compare (matches pip list semantics)
FWU_PLUGIN_TRIPLET_DISP=""
# lookup_firmware_recommendation: CSV row existed but min_plugin_version not met
FWU_REC_PLUGIN_BLOCKED="0"
FWU_REC_NEED_PLUGIN=""
FWU_REC_HAVE_PLUGIN=""

# Trim leading/trailing whitespace (bash)
_str_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# True if file contains [mcu cartographer] or [mcu scanner] (Klipper config dump)
_klippy_has_cartographer_section() {
    [[ -f "$1" ]] && grep -qEi '^[[:space:]]*\[mcu[[:space:]]+(cartographer|scanner)\]' "$1" 2>/dev/null
}

find_klippy_log() {
    local p
    local -a candidates=(
        "${HOME}/printer_data/logs/klippy.log"
        "${HOME}/klipper_logs/klippy.log"
        "${HOME}/logs/klippy.log"
        "${HOME}/mainsail_data/logs/klippy.log"
        "${HOME}/fluidd_data/logs/klippy.log"
        "${PWD}/klippy.log"
    )
    # Prefer a log that actually contains [mcu cartographer] / [mcu scanner] (avoid unrelated klippy.log)
    for p in "${candidates[@]}"; do
        if _klippy_has_cartographer_section "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done
    for p in "${candidates[@]}"; do
        if [[ -f "$p" ]]; then
            printf '%s' "$p"
            return 0
        fi
    done
    if [[ -f "${HOME}/printer_data/config/printer.cfg" ]]; then
        p="${HOME}/printer_data/logs/klippy.log"
        [[ -f "$p" ]] && {
            printf '%s' "$p"
            return 0
        }
    fi
    while IFS= read -r p; do
        _klippy_has_cartographer_section "$p" && {
            printf '%s' "$p"
            return 0
        }
    done < <(find "${HOME}" -maxdepth 12 -name 'klippy.log' -type f 2>/dev/null)
    p="$(find "${HOME}" -maxdepth 12 -name 'klippy.log' -type f 2>/dev/null | head -1)"
    if [[ -n "$p" ]]; then
        printf '%s' "$p"
        return 0
    fi
    return 1
}

# Config files that may hold [mcu cartographer] / serial / canbus_uuid (same idea as web_flasher.py)
collect_cartographer_config_files() {
    local f d
    local -a out=()
    f="${HOME}/printer_data/config/printer.cfg"
    [[ -f "$f" ]] && out+=("$f")
    d="${HOME}/printer_data/config/CARTOGRAPHER"
    if [[ -d "$d" ]]; then
        for f in "$d"/*.cfg; do
            [[ -f "$f" ]] && out+=("$f")
        done
    fi
    # Simple [include] expansion from printer.cfg
    if [[ -f "${HOME}/printer_data/config/printer.cfg" ]]; then
        local base dir inc
        base="${HOME}/printer_data/config"
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*\[include[[:space:]]+([^]]+)\] ]] || continue
            inc="${BASH_REMATCH[1]%%#*}"
            inc="$(_str_trim "$inc")"
            [[ -z "$inc" ]] && continue
            if [[ "$inc" == *"*"* ]]; then
                for f in "$base"/$inc; do
                    [[ -f "$f" ]] && out+=("$f")
                done
            else
                f="$base/$inc"
                [[ -f "$f" ]] && out+=("$f")
            fi
        done <"${HOME}/printer_data/config/printer.cfg"
    fi
    # De-dupe while preserving order
    printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}

# Parse [mcu cartographer] / [mcu scanner] blocks: canbus_uuid = … and serial = … (Python; matches Klipper cfg dump)
parse_cartographer_file() {
    local logfile="$1"
    local out

    [[ -f "$logfile" ]] || return 1

    out="$(python3 - "$logfile" <<'PY'
import re
import sys

path = sys.argv[1]


def parse_blocks(lines):
    """Match Klipper-style sections: [mcu cartographer] / [mcu scanner] only.

    Use re.search (not re.match) for canbus_uuid / serial: klippy.log often prefixes
    lines (timestamps, stats, etc.) so the key may not start at column 0.
    Same idea as web_flasher.py (canbus_uuid\\s*[:=]).
    """
    canbus = None
    serial = None
    section_for_canbus = None
    current_section = None
    in_block = False
    for line in lines:
        raw = line.rstrip("\r\n")
        s = raw.strip()
        mhdr = re.match(r"^\s*\[mcu\s+(cartographer|scanner)\]", s, re.I)
        if mhdr:
            current_section = mhdr.group(1).lower()
            in_block = True
            continue
        if s.startswith("["):
            if not re.match(r"^\s*\[mcu\s+(cartographer|scanner)\]", s, re.I):
                in_block = False
            continue
        if not in_block:
            continue
        if not s or s.startswith("#"):
            continue
        m = re.search(r"canbus_uuid\s*[:=]\s*([^\s#]+)", raw, re.I)
        if m:
            canbus = m.group(1).strip()
            section_for_canbus = current_section
            continue
        m = re.search(r"serial\s*[:=]\s*(.+)$", raw, re.I)
        if m:
            serial = m.group(1).split("#")[0].strip().strip('"').strip("'")
            continue
    return canbus, serial, section_for_canbus


with open(path, "r", errors="replace") as fh:
    lines = fh.readlines()

canbus, serial, section_for_canbus = parse_blocks(lines)
if canbus:
    print("CANBUS|" + canbus)
if section_for_canbus:
    print("SECTION|" + section_for_canbus)
if serial:
    print("SERIAL|" + serial)
PY
)" || return 0

    [[ -z "$out" ]] && return 0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local tag="${line%%|*}"
        local val="${line#*|}"
        [[ -z "$CARTO_CANBUS" && "$tag" == CANBUS ]] && CARTO_CANBUS="$val"
        [[ -z "$CARTO_MCU_SECTION" && "$tag" == SECTION ]] && CARTO_MCU_SECTION="$val"
        [[ -z "$CARTO_SERIAL" && "$tag" == SERIAL ]] && CARTO_SERIAL="$val"
    done <<<"$out"
    return 0
}

_append_if_mcu_section() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    _klippy_has_cartographer_section "$f" || return 0
    if [[ -n "$FWU_MCU_SECTION_FILES" ]] && printf '%s\n' "$FWU_MCU_SECTION_FILES" | grep -Fxq "$f" 2>/dev/null; then
        return 0
    fi
    FWU_MCU_SECTION_FILES="${FWU_MCU_SECTION_FILES:+$FWU_MCU_SECTION_FILES$'\n'}$f"
}

gather_cartographer_identity() {
    local f path
    CARTO_SERIAL=""
    CARTO_CANBUS=""
    CARTO_MCU_SECTION=""
    FWU_KLIPPY_LOG_FOUND="no"
    FWU_KLIPPY_LOG_PATH=""
    FWU_MCU_SECTION_FOUND="no"
    FWU_MCU_SECTION_FILES=""

    path="$(find_klippy_log 2>/dev/null || true)"
    if [[ -n "$path" ]]; then
        FWU_KLIPPY_LOG_FOUND="yes"
        FWU_KLIPPY_LOG_PATH="$path"
        parse_cartographer_file "$path"
        _append_if_mcu_section "$path"
    fi

    while IFS= read -r f; do
        [[ -z "$f" || ! -f "$f" ]] && continue
        parse_cartographer_file "$f"
        _append_if_mcu_section "$f"
    done < <(collect_cartographer_config_files)

    # If still empty, try printer.cfg alone (non-standard HOME)
    if [[ -z "$CARTO_SERIAL" && -z "$CARTO_CANBUS" ]]; then
        for f in "${HOME}/printer_data/config/printer.cfg" "${HOME}/klipper_config/printer.cfg"; do
            if [[ -f "$f" ]]; then
                parse_cartographer_file "$f"
                _append_if_mcu_section "$f"
            fi
        done
    fi

    [[ -n "$FWU_MCU_SECTION_FILES" ]] && FWU_MCU_SECTION_FOUND="yes"
}

# Truncate string for box width (ASCII paths; default max scales with _BOX_INNER)
_fwu_trunc() {
    local s="$1"
    local max="${2:-}"
    [[ -z "$max" ]] && max=$((_BOX_INNER - 4))
    if ((${#s} > max)); then
        printf '%s' "${s:0:$((max - 3))}..."
    else
        printf '%s' "$s"
    fi
}

# Center text in a fixed width (for box titles)
_fwu_center_line() {
    local text="$1"
    local width="${2:-$_BOX_INNER}"
    local len=${#text}
    if ((len > width)); then
        text="${text:0:width}"
        len=$width
    fi
    local left=$(( (width - len) / 2 ))
    local right=$(( width - len - left ))
    printf '%*s%s%*s' "$left" '' "$text" "$right" ''
}

# Strip terminal escapes for display-width math (tput sgr0 often emits \e(B before \e[m; those
# bytes are invisible but were inflating visible length and misaligning the right | in boxes).
# CSI: use $'' so \x1b is a real ESC; charset selects must be separate patterns (BRE treats (.) oddly).
_fwu_strip_ansi_for_width() {
    printf '%s' "$1" | sed \
        -e $'s/\x1b\[[0-9:;<=>?]*[a-zA-Z]//g' \
        -e $'s/\x1b(B//g' \
        -e $'s/\x1b(0//g' \
        -e $'s/\x1b)0//g'
}

# Visible character length (ANSI / charset escapes stripped; width matches terminal display)
_fwu_visible_len() {
    local s="$1"
    local stripped
    stripped="$(_fwu_strip_ansi_for_width "$s")"
    printf '%s' "${#stripped}"
}

# Pad inner to exactly $_BOX_INNER visible columns, then append spaces (ANSI-safe for border alignment)
_fwu_box_pad_inner() {
    local inner="$1"
    local vis pad stripped
    vis="$(_fwu_visible_len "$inner")"
    if (( vis > _BOX_INNER )); then
        stripped="$(_fwu_strip_ansi_for_width "$inner")"
        printf '%s' "${stripped:0:_BOX_INNER}"
        return 0
    fi
    pad=$((_BOX_INNER - vis))
    (( pad < 0 )) && pad=0
    printf '%s%*s' "$inner" "$pad" ''
}

# One box content row: left border | padded inner | reset (right | aligns across rows)
_fwu_box_row() {
    local accent="$1" reset="$2" inner="$3"
    printf '%s|%s|%s\n' "$accent" "$(_fwu_box_pad_inner "$inner")" "$reset"
}

device_name_from_serial_path() {
    local s="$1"
    if [[ "$s" =~ /dev/serial/by-id/([^[:space:]]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    # Rare shorthand paths
    if [[ "$s" =~ /serial/by-id/([^[:space:]]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$s" == /* ]]; then
        basename "$s"
        return 0
    fi
    printf '%s' "$s"
}

urlencode_path_segment() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null || printf '%s' "$1"
}

_api_json_looks_like_cartographer() {
    local f="$1"
    [[ -s "$f" ]] && grep -qE '"serial_number"|"device_uuid"|"mcu_type"|"firmware_version"' "$f" 2>/dev/null
}

query_cartographer_api_v4() {
    local device_name="$1"
    local url tmp code enc
    [[ -z "$device_name" ]] && return 1

    enc="$(urlencode_path_segment "$device_name")"
    url="${_API_BASE}/${enc}?update=1"
    tmp="$(mktemp "${TMPDIR:-/tmp}/fwu.XXXXXX")"
    code="$(curl -sS -o "$tmp" -w "%{http_code}" --connect-timeout 10 --max-time 25 "$url" 2>/dev/null || echo "000")"

    if [[ "$code" == "200" ]] && _api_json_looks_like_cartographer "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# CAN: https://api.cartographer3d.com/q/uuid/<hex>?update=1
query_cartographer_api_v4_by_uuid() {
    local uuid="$1"
    local url tmp code enc
    [[ -z "$uuid" ]] && return 1

    enc="$(urlencode_path_segment "$uuid")"
    url="${_API_UUID_BASE}/${enc}?update=1"
    tmp="$(mktemp "${TMPDIR:-/tmp}/fwu.XXXXXX")"
    code="$(curl -sS -o "$tmp" -w "%{http_code}" --connect-timeout 10 --max-time 25 "$url" 2>/dev/null || echo "000")"

    if [[ "$code" == "200" ]] && _api_json_looks_like_cartographer "$tmp"; then
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Query Moonraker objects/query for mcu cartographer | mcu scanner (object name without brackets)
query_moonraker_mcu_object() {
    local kind="${1:-cartographer}"
    local tmp code url q
    tmp="$(mktemp "${TMPDIR:-/tmp}/fwu.XXXXXX")"
    case "$kind" in
        scanner) q="mcu%20scanner" ;;
        cartographer | *) q="mcu%20cartographer" ;;
    esac
    for url in \
        "http://127.0.0.1/printer/objects/query?${q}" \
        "http://localhost/printer/objects/query?${q}" \
        "http://127.0.0.1:7125/printer/objects/query?${q}" \
        "http://localhost:7125/printer/objects/query?${q}"; do
        code="$(curl -sS -o "$tmp" -w "%{http_code}" --connect-timeout 2 --max-time 8 "$url" 2>/dev/null || echo "000")"
        if [[ "$code" == "200" ]] && [[ -s "$tmp" ]]; then
            cat "$tmp"
            rm -f "$tmp"
            return 0
        fi
    done
    rm -f "$tmp"
    return 1
}

extract_canbus_frequency() {
    local json="$1"
    FWU_CANBUS_FREQUENCY=""
    [[ -z "$json" ]] && return 1
    local v
    v="$(grep -oE '"CANBUS_FREQUENCY"[[:space:]]*:[[:space:]]*[0-9]+' <<<"$json" 2>/dev/null | head -1 | grep -oE '[0-9]+$' || true)"
    [[ -n "$v" ]] && FWU_CANBUS_FREQUENCY="$v"
}

# Parse semver from Moonraker objects/query JSON (mcu_version string, e.g. CARTOGRAPHER V4 6.1.0) -> CURRENTFW
extract_current_fw_from_moonraker_json() {
    local json="$1"
    CURRENTFW=""
    [[ -z "$json" ]] && return 1
    CURRENTFW="$(
        printf '%s' "$json" | python3 -c '
import json, sys, re

def find_mcu_version(obj):
    if isinstance(obj, dict):
        if "mcu_version" in obj and isinstance(obj["mcu_version"], str):
            return obj["mcu_version"]
        for v in obj.values():
            r = find_mcu_version(v)
            if r:
                return r
    elif isinstance(obj, list):
        for x in obj:
            r = find_mcu_version(x)
            if r:
                return r
    return None

try:
    j = json.load(sys.stdin)
    raw = find_mcu_version(j)
    if not raw:
        sys.exit(1)
    m = re.search(r"(\d+\.\d+\.\d+)", raw)
    if not m:
        m = re.search(r"(\d+\.\d+)", raw)
    if not m:
        sys.exit(1)
    print(m.group(1))
except Exception:
    sys.exit(1)
' 2>/dev/null
    )" || true
    [[ -n "${CURRENTFW:-}" ]] || return 1
    return 0
}

is_v3_mcu_in_response() {
    local json="$1"
    [[ -z "$json" ]] && return 1
    grep -q 'stm32f042x6' <<<"$json"
}

# V4 CAN probes: Moonraker object query often reports stm32g431xx (USB path uses REST API instead)
is_v4_mcu_in_response() {
    local json="$1"
    [[ -z "$json" ]] && return 1
    grep -qiE 'stm32g431|stm32g474' <<<"$json"
}

detect_probe() {
    DETECTED_PROBE="unknown"
    FWU_V4_VIA=""
    FWU_CANBUS_FREQUENCY=""
    CURRENTFW=""
    local json devname moon_kind

    gather_cartographer_identity

    if [[ -n "$CARTO_SERIAL" ]]; then
        devname="$(device_name_from_serial_path "$CARTO_SERIAL")"
        if query_cartographer_api_v4 "$devname"; then
            DETECTED_PROBE="v4"
            FWU_V4_VIA="api_usb"
            moon_kind="${CARTO_MCU_SECTION:-cartographer}"
            [[ "$moon_kind" != "scanner" && "$moon_kind" != "cartographer" ]] && moon_kind="cartographer"
            json="$(query_moonraker_mcu_object "$moon_kind" || true)"
            extract_canbus_frequency "$json" || true
            extract_current_fw_from_moonraker_json "$json" || true
            return 0
        fi
    fi

    if [[ -n "$CARTO_CANBUS" ]]; then
        if query_cartographer_api_v4_by_uuid "$CARTO_CANBUS"; then
            DETECTED_PROBE="v4"
            FWU_V4_VIA="api_uuid"
            moon_kind="${CARTO_MCU_SECTION:-cartographer}"
            [[ "$moon_kind" != "scanner" && "$moon_kind" != "cartographer" ]] && moon_kind="cartographer"
            json="$(query_moonraker_mcu_object "$moon_kind" || true)"
            extract_canbus_frequency "$json" || true
            extract_current_fw_from_moonraker_json "$json" || true
            return 0
        fi
    fi

    # Moonraker: use mcu scanner vs mcu cartographer to match config; on CAN also capture CANBUS_FREQUENCY
    moon_kind="${CARTO_MCU_SECTION:-cartographer}"
    [[ "$moon_kind" != "scanner" && "$moon_kind" != "cartographer" ]] && moon_kind="cartographer"

    if [[ -n "$CARTO_CANBUS" ]]; then
        json="$(query_moonraker_mcu_object "$moon_kind" || true)"
        extract_canbus_frequency "$json" || true
    else
        json="$(query_moonraker_mcu_object cartographer || true)"
    fi

    extract_current_fw_from_moonraker_json "$json" || true

    if is_v3_mcu_in_response "$json"; then
        DETECTED_PROBE="v3"
        return 0
    fi
    if is_v4_mcu_in_response "$json"; then
        DETECTED_PROBE="v4"
        FWU_V4_VIA="moonraker"
        return 0
    fi

    return 0
}

# CAN vs USB from Klipper config (canbus_uuid wins over serial)
set_fwu_protocol_and_can() {
    FWU_PROTOCOL="unknown"
    FWU_CAN_SPEED=""
    FWU_CAN_SPEED_ASSUMED="no"
    if [[ -n "${CARTO_CANBUS:-}" ]]; then
        FWU_PROTOCOL="CAN"
        case "${FWU_CANBUS_FREQUENCY:-}" in
            250000 | 500000 | 1000000)
                FWU_CAN_SPEED="$FWU_CANBUS_FREQUENCY"
                ;;
            *)
                FWU_CAN_SPEED="1000000"
                FWU_CAN_SPEED_ASSUMED="yes"
                ;;
        esac
    elif [[ -n "${CARTO_SERIAL:-}" ]]; then
        FWU_PROTOCOL="USB"
    fi
}

detect_cartographer_plugin_version() {
    FWU_PLUGIN_VERSION_RAW=""
    FWU_PLUGIN_TRIPLET_DISP=""
    local pip_exe="${HOME}/klippy-env/bin/pip"
    [[ -x "$pip_exe" ]] || return 0
    local pline raw
    pline="$("$pip_exe" list 2>/dev/null | grep -i '^cartographer3d-plugin[[:space:]]' | head -1 || true)"
    [[ -z "$pline" ]] && return 0
    raw="$(printf '%s\n' "$pline" | awk '{ print $NF }')"
    [[ -z "$raw" ]] && return 0
    FWU_PLUGIN_VERSION_RAW="$raw"
    FWU_PLUGIN_TRIPLET_DISP="$(
        python3 -c "import re, sys; m = re.match(r'^(\d+\.\d+\.\d+)', sys.argv[1]); print(m.group(1) if m else '')" "$raw"
    )"
    return 0
}

# After user picks FWU_FW_VERSION_CHOSEN: if CSV min_plugin_version is not met, run pip upgrade.
fwu_maybe_upgrade_plugin_for_chosen_firmware() {
    local want="${FWU_FW_VERSION_CHOSEN:-}"
    local csv="${_SCRIPT_DIR}/firmware_list.csv"
    local can_arg need_line min_ver pip_exe

    [[ -n "$want" ]] || return 0
    [[ -f "$csv" ]] || return 0
    if [[ "$DETECTED_PROBE" != v3 && "$DETECTED_PROBE" != v4 ]]; then
        return 0
    fi
    if [[ "$FWU_PROTOCOL" != "CAN" && "$FWU_PROTOCOL" != "USB" ]]; then
        return 0
    fi

    can_arg="${FWU_CAN_SPEED:-}"
    need_line="$(
        python3 - "$DETECTED_PROBE" "$FWU_PROTOCOL" "$can_arg" "$csv" "$want" "${FWU_PLUGIN_VERSION_RAW:-}" <<'PY'
import csv
import re
import sys


def plugin_triplet_from_pip(ver_raw: str):
    ver_raw = (ver_raw or "").strip()
    if not ver_raw:
        return None
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", ver_raw)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)))


def row_min_plugin_tuple(row: dict):
    s = (row.get("min_plugin_version") or "").strip()
    if not s:
        return None
    parts = s.split(".")
    try:
        return tuple(int(p) for p in parts[:3])
    except ValueError:
        return None


probe, proto, can_speed, csv_path = sys.argv[1:5]
want_ver = (sys.argv[5] if len(sys.argv) > 5 else "").strip()
plugin_raw = (sys.argv[6] if len(sys.argv) > 6 else "").strip()
can_speed = (can_speed or "").strip()
installed_tp = plugin_triplet_from_pip(plugin_raw)

rows: list = []
try:
    with open(csv_path, newline="", encoding="utf-8") as f:
        rdr = csv.DictReader(f)
        for row in rdr:
            if row.get("process", "").strip() != "Update":
                continue
            if row.get("firmware_type", "").strip() != "Cartographer":
                continue
            if row.get("probe_version", "").strip() != probe:
                continue
            if row.get("protocol", "").strip() != proto:
                continue
            cs = row.get("can_speed", "").strip()
            if proto == "CAN":
                if cs != can_speed:
                    continue
            else:
                if cs:
                    continue
            if row.get("firmware_version", "").strip() != want_ver:
                continue
            rows.append(row)
except OSError:
    print("OK")
    sys.exit(0)

reqs = [row_min_plugin_tuple(r) for r in rows]
reqs = [x for x in reqs if x is not None]
if not reqs:
    print("OK")
    sys.exit(0)

strict = max(reqs)
if installed_tp is not None and installed_tp >= strict:
    print("OK")
    sys.exit(0)

print("NEED %d.%d.%d" % strict)
sys.exit(0)
PY
    )"

    [[ "$need_line" == NEED\ * ]] || return 0
    min_ver="${need_line#NEED }"

    echo ""
    printf '%s\n' "  Firmware ${want} needs cartographer3d-plugin ${min_ver} or newer (see min_plugin_version in firmware_list.csv)."
    printf '%s\n' "  Upgrading cartographer3d-plugin in ~/klippy-env now:"
    printf '%s\n' "    ~/klippy-env/bin/pip install --upgrade cartographer3d-plugin"
    echo ""

    pip_exe="${HOME}/klippy-env/bin/pip"
    if [[ ! -x "$pip_exe" ]]; then
        printf '%s\n' "  ERROR: ${pip_exe} not found or not executable. Install or upgrade the plugin manually, then re-run this script."
        return 0
    fi
    if ! "$pip_exe" install --upgrade cartographer3d-plugin; then
        printf '%s\n' "  WARNING: pip install failed. Fix the error above or upgrade the plugin manually, then retry."
    fi
    detect_cartographer_plugin_version
    return 0
}

enumerate_firmware_versions() {
    FWU_VERSIONS_AVAILABLE=""
    FWU_VER_LATEST=""
    local csv="${_SCRIPT_DIR}/firmware_list.csv"
    [[ -f "$csv" ]] || return 1
    if [[ "$DETECTED_PROBE" != v3 && "$DETECTED_PROBE" != v4 ]]; then
        return 1
    fi
    if [[ "$FWU_PROTOCOL" != "CAN" && "$FWU_PROTOCOL" != "USB" ]]; then
        return 1
    fi
    local can_arg="${FWU_CAN_SPEED:-}"
    FWU_VERSIONS_AVAILABLE="$(
        python3 - "$DETECTED_PROBE" "$FWU_PROTOCOL" "$can_arg" "$csv" <<'PY'
import csv
import sys


def parse_version(s: str) -> tuple:
    s = (s or "").strip()
    if not s:
        return (0, 0, 0)
    parts = s.split(".")
    try:
        return tuple(int(p) for p in parts[:3])
    except ValueError:
        return (0, 0, 0)


probe, proto, can_speed, csv_path = sys.argv[1:5]
can_speed = (can_speed or "").strip()
rows: list = []
try:
    with open(csv_path, newline="", encoding="utf-8") as f:
        rdr = csv.DictReader(f)
        for row in rdr:
            if row.get("process", "").strip() != "Update":
                continue
            if row.get("firmware_type", "").strip() != "Cartographer":
                continue
            if row.get("probe_version", "").strip() != probe:
                continue
            if row.get("protocol", "").strip() != proto:
                continue
            cs = row.get("can_speed", "").strip()
            if proto == "CAN":
                if cs != can_speed:
                    continue
            else:
                if cs:
                    continue
            rows.append(row)
except OSError:
    sys.exit(0)

if not rows:
    sys.exit(0)

versions = sorted({r["firmware_version"].strip() for r in rows}, key=parse_version, reverse=True)
for v in versions:
    print(v)
PY
    )" || true
    [[ -n "$FWU_VERSIONS_AVAILABLE" ]] || return 1
    FWU_VER_LATEST="$(printf '%s\n' "$FWU_VERSIONS_AVAILABLE" | head -1)"
    return 0
}

lookup_firmware_recommendation() {
    local want_ver="${1:-}"

    FWU_REC_NO_MATCH="1"
    FWU_REC_VERSION=""
    FWU_REC_HAS_FULL="0"
    FWU_REC_HAS_LITE="0"
    FWU_REC_FULL_PATH=""
    FWU_REC_FULL_FILE=""
    FWU_REC_LITE_PATH=""
    FWU_REC_LITE_FILE=""
    FWU_FW_SELECTED_KIND=""
    FWU_FW_SELECTED_PATH=""
    FWU_FW_SELECTED_FILE=""
    FWU_REC_PLUGIN_BLOCKED="0"
    FWU_REC_NEED_PLUGIN=""
    FWU_REC_HAVE_PLUGIN=""

    local csv="${_SCRIPT_DIR}/firmware_list.csv"
    [[ -f "$csv" ]] || return 0

    if [[ "$DETECTED_PROBE" != v3 && "$DETECTED_PROBE" != v4 ]]; then
        return 0
    fi
    if [[ "$FWU_PROTOCOL" != "CAN" && "$FWU_PROTOCOL" != "USB" ]]; then
        return 0
    fi

    local can_arg="${FWU_CAN_SPEED:-}"
    local plugin_raw="${FWU_PLUGIN_VERSION_RAW:-}"
    # shellcheck disable=SC1090
    eval "$(python3 - "$DETECTED_PROBE" "$FWU_PROTOCOL" "$can_arg" "$csv" "$want_ver" "$plugin_raw" <<'PY'
import csv
import re
import shlex
import sys


def parse_version(s: str) -> tuple:
    s = (s or "").strip()
    if not s:
        return (0, 0, 0)
    parts = s.split(".")
    try:
        return tuple(int(p) for p in parts[:3])
    except ValueError:
        return (0, 0, 0)


def emit(key: str, val: str) -> None:
    print(f"{key}={shlex.quote(val)}")


def is_lite_row(row: dict) -> bool:
    v = (row.get("is_lite") or "").strip().lower()
    return v in ("yes", "true", "1", "y")


def plugin_triplet_from_pip(ver_raw: str):
    ver_raw = (ver_raw or "").strip()
    if not ver_raw:
        return None
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", ver_raw)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)))


def row_min_plugin_tuple(row: dict):
    s = (row.get("min_plugin_version") or "").strip()
    if not s:
        return None
    parts = s.split(".")
    try:
        return tuple(int(p) for p in parts[:3])
    except ValueError:
        return None


def row_plugin_ok(installed_tp, row: dict) -> bool:
    need = row_min_plugin_tuple(row)
    if need is None:
        return True
    if installed_tp is None:
        return False
    return installed_tp >= need


probe, proto, can_speed, csv_path = sys.argv[1:5]
want_ver = (sys.argv[5] if len(sys.argv) > 5 else "").strip()
plugin_raw = (sys.argv[6] if len(sys.argv) > 6 else "").strip()
can_speed = (can_speed or "").strip()
installed_tp = plugin_triplet_from_pip(plugin_raw)

rows: list = []
try:
    with open(csv_path, newline="", encoding="utf-8") as f:
        rdr = csv.DictReader(f)
        for row in rdr:
            if row.get("process", "").strip() != "Update":
                continue
            if row.get("firmware_type", "").strip() != "Cartographer":
                continue
            if row.get("probe_version", "").strip() != probe:
                continue
            if row.get("protocol", "").strip() != proto:
                continue
            cs = row.get("can_speed", "").strip()
            if proto == "CAN":
                if cs != can_speed:
                    continue
            else:
                if cs:
                    continue
            rows.append(row)
except OSError as e:
    emit("FWU_REC_NO_MATCH", "1")
    emit("FWU_REC_ERR", str(e))
    sys.exit(0)

if not rows:
    emit("FWU_REC_NO_MATCH", "1")
    sys.exit(0)

rows_compatible = [r for r in rows if row_plugin_ok(installed_tp, r)]

if want_ver:
    rw = [r for r in rows if r["firmware_version"].strip() == want_ver]
    rw_ok = [r for r in rows_compatible if r["firmware_version"].strip() == want_ver]
    if not rw:
        emit("FWU_REC_NO_MATCH", "1")
        sys.exit(0)
    if not rw_ok:
        need_cell = ""
        for r in rw:
            mt = row_min_plugin_tuple(r)
            if mt is not None:
                need_cell = ".".join(str(x) for x in mt)
                break
        have = plugin_raw.strip() if plugin_raw else ""
        if not have:
            have = "not detected (install via ~/klippy-env/bin/pip list)"
        emit("FWU_REC_PLUGIN_BLOCKED", "1")
        emit("FWU_REC_NEED_PLUGIN", need_cell)
        emit("FWU_REC_HAVE_PLUGIN", have)
        emit("FWU_REC_NO_MATCH", "1")
        sys.exit(0)
    rows = rw_ok
    best_ver = want_ver
else:
    if not rows_compatible:
        emit("FWU_REC_NO_MATCH", "1")
        sys.exit(0)
    best_ver = max((r["firmware_version"].strip() for r in rows_compatible), key=parse_version)
    rows = [r for r in rows_compatible if r["firmware_version"].strip() == best_ver]

full_rows = [r for r in rows if not is_lite_row(r)]
lite_rows = [r for r in rows if is_lite_row(r)]
full_rows.sort(key=lambda x: x.get("filepath", ""))
lite_rows.sort(key=lambda x: x.get("filepath", ""))

emit("FWU_REC_NO_MATCH", "0")
emit("FWU_REC_VERSION", best_ver)
emit("FWU_REC_HAS_FULL", "1" if full_rows else "0")
emit("FWU_REC_HAS_LITE", "1" if lite_rows else "0")
if full_rows:
    emit("FWU_REC_FULL_PATH", full_rows[0].get("filepath", ""))
    emit("FWU_REC_FULL_FILE", full_rows[0].get("filename", ""))
else:
    emit("FWU_REC_FULL_PATH", "")
    emit("FWU_REC_FULL_FILE", "")
if lite_rows:
    emit("FWU_REC_LITE_PATH", lite_rows[0].get("filepath", ""))
    emit("FWU_REC_LITE_FILE", lite_rows[0].get("filename", ""))
else:
    emit("FWU_REC_LITE_PATH", "")
    emit("FWU_REC_LITE_FILE", "")
PY
)"
}

# Normalize user input like "1" -> can1, "CAN2" -> can2
_fwu_normalize_can_if() {
    local raw="$1"
    raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    if [[ -z "$raw" ]]; then
        printf '%s' "can0"
        return 0
    fi
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf '%s' "can${raw}"
        return 0
    fi
    printf '%s' "$raw"
}

# Print chosen firmware version (x.y.z) to stdout only (prompts go to stderr; use with $(...))
_fwu_menu_pick_firmware_version() {
    local -a list
    local _i _n _line
    list=()
    while IFS= read -r ver; do
        [[ -z "$ver" ]] && continue
        list+=("$ver")
    done <<<"$FWU_VERSIONS_AVAILABLE"
    _n=${#list[@]}
    [[ "$_n" -ge 1 ]] || return 1
    printf '%s\n' "  Select firmware version:" >&2
    for ((_i = 0; _i < _n; _i++)); do
        printf '%s\n' "    $((_i + 1)) - ${list[$_i]}" >&2
    done
    # read from /dev/tty so this works when called as $(...) (stdin is not the terminal)
    if [[ -r /dev/tty ]]; then
        read -r -p "  Enter choice [1]: " _line </dev/tty || true
    else
        read -r -p "  Enter choice [1]: " _line || true
    fi
    _line="${_line:-1}"
    _line="${_line//[^0-9]/}"
    [[ -z "$_line" ]] && _line=1
    if [[ "$_line" -ge 1 && "$_line" -le "$_n" ]]; then
        printf '%s' "${list[$((_line - 1))]}"
        return 0
    fi
    printf '%s' "${list[0]}"
    return 0
}

# Print "full" or "lite" to stdout only (prompts to stderr)
_fwu_menu_pick_build_type() {
    local _full _lite _line
    # Same copy as the firmware recommendation box (Full default; Lite for slow hosts / K1 / Qidi-class)
    _full="1 - Full (recommended). Full Klipper firmware; best for most Raspberry Pi and host PCs (default)."
    _lite="2 - Lite. For slower hosts: Pi 2-class SBCs, or host MCUs such as Creality K1 / Qidi, where Full can overload the bus or CPU."
    printf '%s\n' "  ${_full}" >&2
    printf '%s\n' "  ${_lite}" >&2
    printf '%s\n' "  Build type:" >&2
    if [[ -r /dev/tty ]]; then
        read -r -p "  Enter choice [1]: " _line </dev/tty || true
    else
        read -r -p "  Enter choice [1]: " _line || true
    fi
    _line="${_line:-1}"
    _line="$(printf '%s' "$_line" | tr -d '[:space:]')"
    case "$_line" in
        2) printf '%s' lite ;;
        *) printf '%s' full ;;
    esac
    return 0
}

# Bordered "Thank you" only (no report payload)
_fwu_print_thanks_box_simple() {
    local bold="$1" reset="$2" accent="$3" body="$4"
    local line
    line="$(printf '%*s' "$_BOX_INNER" '' | tr ' ' '-')"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    printf '%s|%s%s%s%s|%s\n' "$accent" "$bold" "$(_fwu_center_line 'Thank you')" "$reset" "$accent" "$reset"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    _fwu_box_row "$accent" "$reset" "${body}  Thank you for updating your Cartographer probe firmware."
    _fwu_box_row "$accent" "$reset" "${body}  You may send a one-time anonymous usage report to help us estimate how many probes are in use and which firmware, link (USB vs CAN), and build (Full vs Lite) are common."
    _fwu_box_row "$accent" "$reset" "${body}  No personal information is collected or stored. Data is used only for aggregate statistics and will never be sold."
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
}

# Thank you + optional report explainer + exact fields (uses FWU_REPORT_*; no URL shown)
# body = accent (body copy); val_hl = bold+white for "what we send" values
_fwu_print_thanks_box_with_report() {
    local bold="$1" reset="$2" accent="$3" body="$4" val_hl="$5"
    local line _id
    line="$(printf '%*s' "$_BOX_INNER" '' | tr ' ' '-')"
    _id="$(_fwu_trunc "${FWU_REPORT_IDENTIFIER}" $((_BOX_INNER - 18)))"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    printf '%s|%s%s%s%s|%s\n' "$accent" "$bold" "$(_fwu_center_line 'Thank you')" "$reset" "$accent" "$reset"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    _fwu_box_row "$accent" "$reset" "${body}  Thank you for updating your Cartographer probe firmware."
    _fwu_box_row "$accent" "$reset" "${body}  Optional anonymous usage report - see exactly what is sent below."
    _fwu_box_row "$accent" "$reset" "${body}  Why this helps: we learn how many probes are in use and which firmware, USB vs CAN, and "
    _fwu_box_row "$accent" "$reset" "${body}  Full vs Lite are common - to focus support and testing."
    _fwu_box_row "$accent" "$reset" "${bold}  What we send (one anonymous GET request)${reset}"
    _fwu_box_row "$accent" "$reset" "${body}    protocol:      ${val_hl}${FWU_REPORT_PROTOCOL}${reset}"
    _fwu_box_row "$accent" "$reset" "${body}    probe_version: ${val_hl}${FWU_REPORT_PROBE_VERSION}${reset}"
    _fwu_box_row "$accent" "$reset" "${body}    identifier:    ${val_hl}${_id}${reset}"
    _fwu_box_row "$accent" "$reset" "${body}    firmware:      ${val_hl}${FWU_REPORT_FIRMWARE}${reset}"
    _fwu_box_row "$accent" "$reset" "${body}    flavour:       ${val_hl}${FWU_REPORT_FLAVOUR}${reset}"
    if [[ "${FWU_REPORT_PROTOCOL}" == "CAN" ]]; then
        if [[ -n "${FWU_REPORT_BAUD:-}" ]]; then
            _fwu_box_row "$accent" "$reset" "${body}    baudrate:      ${val_hl}${FWU_REPORT_BAUD}${reset}"
        else
            _fwu_box_row "$accent" "$reset" "${body}    baudrate:      ${val_hl}(not set; omitted from request)${reset}"
        fi
    fi
    _fwu_box_row "$accent" "$reset" "${bold}  What is not sent${reset}"
    _fwu_box_row "$accent" "$reset" "${body}  No Klipper config, printer name, location, or account details. Identifier above is an "
    _fwu_box_row "$accent" "$reset" "${body}  anonymous probe id. Aggregate stats only; never sold."
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
}

# Plain-text report summary for non-TTY (no URL)
_fwu_print_report_summary_plain() {
    printf '%s\n' "  What we send (one anonymous request):"
    printf '%s\n' "    protocol:      ${FWU_REPORT_PROTOCOL}"
    printf '%s\n' "    probe_version: ${FWU_REPORT_PROBE_VERSION}"
    printf '%s\n' "    identifier:    ${FWU_REPORT_IDENTIFIER}"
    printf '%s\n' "    firmware:      ${FWU_REPORT_FIRMWARE}"
    printf '%s\n' "    flavour:       ${FWU_REPORT_FLAVOUR}"
    if [[ "${FWU_REPORT_PROTOCOL}" == "CAN" ]]; then
        if [[ -n "${FWU_REPORT_BAUD:-}" ]]; then
            printf '%s\n' "    baudrate:      ${FWU_REPORT_BAUD}"
        else
            printf '%s\n' "    baudrate:      (not set; omitted from request)"
        fi
    fi
    printf '%s\n' "  What is not sent: no Klipper config, printer name, location, or account details."
}

# Hex string for flash_can.py -u (strip colons/dashes, 0x)
_fwu_canbus_uuid_for_flash() {
    local u="$1"
    u="${u//:/}"
    u="${u//-/}"
    u="${u#0x}"
    u="${u#0X}"
    u="$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]')"
    printf '%s' "$u"
}

# Katapult source (optional reference; clone if missing)
ensure_katapult_clone() {
    if [[ ! -d "${HOME}/katapult" ]]; then
        echo "Cloning Katapult into ${HOME}/katapult ..."
        git clone https://github.com/Arksine/katapult.git "${HOME}/katapult"
    fi
}

# Flash selected .bin via Klipper flash_can.py (USB: enter bootloader first)
perform_firmware_flash() {
    local red reset fw_root fw_bin fw_dir fw_name klipper klippy flash_can
    red=$(tput setaf 1 2>/dev/null || true)
    reset=$(tput sgr0 2>/dev/null || true)

    if [[ -z "${FWU_FW_SELECTED_PATH:-}" ]]; then
        printf '%s\n' "No firmware path selected; skipping flash."
        return 1
    fi

    fw_root="${_SCRIPT_DIR}/firmware"
    fw_bin="${fw_root}/${FWU_FW_SELECTED_PATH}"
    fw_dir="$(dirname "$fw_bin")"
    fw_name="$(basename "$fw_bin")"

    klipper="${HOME}/klipper"
    klippy="${HOME}/klippy-env/bin/python"
    if [[ -f "${klipper}/lib/canboot/flash_can.py" ]]; then
        flash_can="${klipper}/lib/canboot/flash_can.py"
    elif [[ -f "${klipper}/lib/katapult/flashtool.py" ]]; then
        flash_can="${klipper}/lib/katapult/flashtool.py"
    else
    echo "Error: Could not find flash_can.py or flashtool.py"
    echo "Checked:"
    echo "  ${klipper}/lib/canboot/flash_can.py"
    echo "  ${klipper}/lib/katapult/flashtool.py"
    exit 1
fi

    if [[ ! -f "$fw_bin" ]]; then
        printf '%sERROR: Firmware file not found:%s\n%s\n' "$red" "$reset" "$fw_bin"
        return 1
    fi
    if [[ ! -x "$klippy" ]]; then
        printf '%sERROR: Klipper Python not found or not executable:%s\n%s\n' "$red" "$reset" "$klippy"
        return 1
    fi
    if [[ ! -f "$flash_can" ]]; then
        printf '%sERROR: flash_can.py not found:%s\n%s\n' "$red" "$reset" "$flash_can"
        return 1
    fi

    ensure_katapult_clone

    if [[ "$FWU_PROTOCOL" == "USB" ]]; then
        local carto katapult_id _i
        carto="$(ls /dev/serial/by-id/ 2>/dev/null | grep -i cartographer | head -n 1 || true)"
        if [[ -z "$carto" ]]; then
            printf '%sERROR: No Cartographer probe found in /dev/serial/by-id/. Is it plugged in via USB?%s\n' "$red" "$reset"
            return 1
        fi
        if [[ ! -d "${klipper}/scripts" ]]; then
            printf '%sERROR: Missing Klipper scripts directory:%s\n%s\n' "$red" "$reset" "${klipper}/scripts"
            return 1
        fi
        echo "Entering bootloader via flash_usb (Cartographer: ${carto}) ..."
        (cd "${klipper}/scripts" && "$klippy" -c "import flash_usb as u; u.enter_bootloader('/dev/serial/by-id/${carto}')") || {
            printf '%sERROR: enter_bootloader failed.%s\n' "$red" "$reset"
            return 1
        }
        echo "Waiting for Katapult device to appear ..."
        sleep 3
        katapult_id=""
        for ((_i = 1; _i <= 15; _i++)); do
            katapult_id="$(ls /dev/serial/by-id/ 2>/dev/null | grep -i katapult | head -n 1 || true)"
            [[ -n "$katapult_id" ]] && break
            sleep 2
        done
        if [[ -z "$katapult_id" ]]; then
            printf '%sERROR: No Katapult device in /dev/serial/by-id/ after bootloader (waited ~30s).%s\n' "$red" "$reset"
            return 1
        fi
        echo "Flashing ${fw_name} via Katapult (${katapult_id}) ..."
        (cd "$fw_dir" && "$klippy" "$flash_can" -f "$fw_name" -d "/dev/serial/by-id/${katapult_id}") || {
            printf '%sERROR: flash_can.py failed.%s\n' "$red" "$reset"
            return 1
        }
    elif [[ "$FWU_PROTOCOL" == "CAN" ]]; then
        # flash_can.py: with NO -d it uses the CAN bus; -u canbus uuid is required.
        # With -d it uses USB serial to Katapult (probe on CAN may not expose this).
        local katapult_id uuid_hex
        if [[ -n "${CARTO_CANBUS:-}" ]]; then
            uuid_hex="$(_fwu_canbus_uuid_for_flash "${CARTO_CANBUS}")"
            if [[ -z "$uuid_hex" ]]; then
                printf '%sERROR: canbus_uuid from config is empty after normalization.%s\n' "$red" "$reset"
                return 1
            fi
            echo "Flashing ${fw_name} over CAN (interface ${FWU_CAN_INTERFACE}, uuid ${uuid_hex}) ..."
            echo "  (CAN probes do not need a Katapult device under /dev/serial/by-id/.)"
            (cd "$fw_dir" && "$klippy" "$flash_can" -f "$fw_name" -i "${FWU_CAN_INTERFACE}" -u "${uuid_hex}") || {
                printf '%sERROR: flash_can.py failed.%s\n' "$red" "$reset"
                return 1
            }
        else
            katapult_id="$(ls /dev/serial/by-id/ 2>/dev/null | grep -i katapult | head -n 1 || true)"
            if [[ -z "$katapult_id" ]]; then
                printf '%sERROR: No canbus_uuid in Klipper config and no Katapult USB device in /dev/serial/by-id/.%s\n' "$red" "$reset"
                printf '%s  For a probe on the CAN bus, ensure canbus_uuid is in printer.cfg so we can use flash_can.py -u.%s\n' "$red" "$reset"
                printf '%s  Or connect a Katapult USB interface and try again.%s\n' "$red" "$reset"
                return 1
            fi
            echo "Flashing ${fw_name} via Katapult USB (${katapult_id}) ..."
            echo "  (No canbus_uuid in config; using serial -d mode. CAN interface flag may be ignored.)"
            (cd "$fw_dir" && "$klippy" "$flash_can" -f "$fw_name" -d "/dev/serial/by-id/${katapult_id}") || {
                printf '%sERROR: flash_can.py failed.%s\n' "$red" "$reset"
                return 1
            }
        fi
    else
        printf '%sERROR: Protocol is not USB or CAN; cannot flash automatically.%s\n' "$red" "$reset"
        return 1
    fi

    echo "flash_can.py finished."
    return 0
}

# Default: Full; explain Lite for low-power hosts / Creality K1 / Qidi / Pi 2
prompt_full_or_lite() {
    local accent reset _kind
    accent=$(tput setaf 6 2>/dev/null || true)
    reset=$(tput sgr0 2>/dev/null || true)

    FWU_FW_SELECTED_KIND=""
    FWU_FW_SELECTED_PATH=""
    FWU_FW_SELECTED_FILE=""
    if [[ "$FWU_REC_NO_MATCH" == 1 ]]; then
        return 1
    fi
    if [[ "$FWU_REC_HAS_FULL" == 1 && "$FWU_REC_HAS_LITE" == 1 ]]; then
        printf '%s\n' "${accent}  Choose build: type the number for your option.${reset}"
        echo ""
        _kind="$(_fwu_menu_pick_build_type)"
        case "$_kind" in
            lite)
                FWU_FW_SELECTED_KIND="lite"
                FWU_FW_SELECTED_PATH="${FWU_REC_LITE_PATH}"
                FWU_FW_SELECTED_FILE="${FWU_REC_LITE_FILE}"
                ;;
            *)
                FWU_FW_SELECTED_KIND="full"
                FWU_FW_SELECTED_PATH="${FWU_REC_FULL_PATH}"
                FWU_FW_SELECTED_FILE="${FWU_REC_FULL_FILE}"
                ;;
        esac
    elif [[ "$FWU_REC_HAS_FULL" == 1 ]]; then
        FWU_FW_SELECTED_KIND="full"
        FWU_FW_SELECTED_PATH="${FWU_REC_FULL_PATH}"
        FWU_FW_SELECTED_FILE="${FWU_REC_FULL_FILE}"
    elif [[ "$FWU_REC_HAS_LITE" == 1 ]]; then
        FWU_FW_SELECTED_KIND="lite"
        FWU_FW_SELECTED_PATH="${FWU_REC_LITE_PATH}"
        FWU_FW_SELECTED_FILE="${FWU_REC_LITE_FILE}"
    else
        return 1
    fi
    return 0
}

show_firmware_recommendation() {
    local bold reset accent body white val_hl red
    if [[ -t 1 ]]; then
        bold=$(tput bold 2>/dev/null || true)
        reset=$(tput sgr0 2>/dev/null || true)
        accent=$(tput setaf 6 2>/dev/null || true)
        body="${accent}"
        white=$(tput setaf 7 2>/dev/null || true)
        val_hl="${bold}${white}"
        red=$(tput setaf 1 2>/dev/null || true)
    else
        bold="" reset="" accent="" body="" white="" val_hl="" red=""
    fi

    local line _ver_in _can_in _avail_line _v
    line="$(printf '%*s' "$_BOX_INNER" '' | tr ' ' '-')"

    FWU_FW_VERSION_CHOSEN=""
    FWU_CAN_INTERFACE="can0"

    clear 2>/dev/null || true

    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    printf '%s|%s%s%s%s|%s\n' "$accent" "$bold" "$(_fwu_center_line 'Firmware recommendation')" "$reset" "$accent" "$reset"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"

    if [[ "$DETECTED_PROBE" != v3 && "$DETECTED_PROBE" != v4 ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Probe type is unknown; cannot pick a firmware file yet.')" "$reset"
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
        printf '%s+%s+%s\n' "$accent" "$line" "$reset"
        echo ""
        return 0
    fi

    if [[ "$FWU_PROTOCOL" == "unknown" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  No canbus_uuid or serial found in config; protocol unknown.')" "$reset"
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
        printf '%s+%s+%s\n' "$accent" "$line" "$reset"
        echo ""
        return 0
    fi

    if [[ "$FWU_PROTOCOL" == "CAN" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  Protocol: CAN  (${FWU_CAN_SPEED} baud)")" "$reset"
        if [[ "$FWU_CAN_SPEED_ASSUMED" == yes ]]; then
            printf '%s|%s%s%s%s|%s\n' "$accent" "$accent" "$(printf '%-*s' "$_BOX_INNER" '  (Moonraker did not report CANBUS_FREQUENCY; using 1000000.)')" "$reset" "$accent" "$reset"
        fi
    else
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Protocol: USB')" "$reset"
    fi
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  Probe: ${DETECTED_PROBE}")" "$reset"
    if [[ -t 1 ]]; then
        if [[ -n "${CURRENTFW:-}" ]]; then
            _fwu_box_row "$accent" "$reset" "  Current firmware (running): ${red}${CURRENTFW}${reset}"
        else
            _fwu_box_row "$accent" "$reset" "  Current firmware (running): not reported"
        fi
    else
        if [[ -n "${CURRENTFW:-}" ]]; then
            printf '%s\n' "  Current firmware (running): ${CURRENTFW}"
        else
            printf '%s\n' "  Current firmware (running): not reported"
        fi
    fi
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"

    detect_cartographer_plugin_version
    if [[ -n "$FWU_PLUGIN_TRIPLET_DISP" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  Klipper cartographer3d-plugin: ${FWU_PLUGIN_TRIPLET_DISP} (${FWU_PLUGIN_VERSION_RAW})")" "$reset"
    elif [[ -n "${FWU_PLUGIN_VERSION_RAW:-}" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  Klipper cartographer3d-plugin: ${FWU_PLUGIN_VERSION_RAW} (could not parse X.Y.Z)")" "$reset"
    elif [[ -x "${HOME}/klippy-env/bin/pip" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Klipper cartographer3d-plugin: not listed in ~/klippy-env (upgrade from your plugin source).')" "$reset"
    else
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Klipper cartographer3d-plugin: ~/klippy-env/bin/pip not found; detection skipped.')" "$reset"
    fi
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"

    if ! enumerate_firmware_versions; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  No matching firmware rows in firmware_list.csv for this probe and link.')" "$reset"
        printf '%s|%s%s%s%s|%s\n' "$accent" "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Check firmware_list.csv next to this script.')" "$reset" "$accent" "$reset"
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
        printf '%s+%s+%s\n' "$accent" "$line" "$reset"
        echo ""
        return 0
    fi

    _avail_line=""
    while IFS= read -r _v; do
        [[ -z "$_v" ]] && continue
        [[ -n "$_avail_line" ]] && _avail_line+=", "
        _avail_line+="$_v"
    done <<<"$FWU_VERSIONS_AVAILABLE"
    _avail_line="$(_fwu_trunc "${_avail_line}" $((_BOX_INNER - 22)))"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  Available versions: ${_avail_line}")" "$reset"
    printf '%s|%s%s%s%s|%s\n' "$accent" "$accent" "$(printf '%-*s' "$_BOX_INNER" '  (newest listed first; you can choose below)')" "$reset" "$accent" "$reset"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    echo ""

    if [[ "$FWU_PROTOCOL" == "CAN" ]]; then
        printf '%s\n' "${accent}  Linux CAN network (for flashing tools that use ip link / socketcan).${reset}"
        printf '%s\n' "  Default is can0; use can1 or can2 if your adapter shows up that way."
        read -r -p "  CAN interface [can0]: " _can_in || true
        FWU_CAN_INTERFACE="$(_fwu_normalize_can_if "${_can_in:-}")"
        printf '%s\n' "  Using CAN interface: ${FWU_CAN_INTERFACE}"
        echo ""
    fi

    printf '%s\n' "${accent}  Choose firmware version: type the number for your option.${reset}"
    echo ""
    _ver_in="$(_fwu_menu_pick_firmware_version)" || _ver_in=""
    _ver_in="${_ver_in:-$FWU_VER_LATEST}"
    _ver_in="${_ver_in#"${_ver_in%%[![:space:]]*}"}"
    _ver_in="${_ver_in%"${_ver_in##*[![:space:]]}"}"
    if [[ -z "$_ver_in" ]]; then
        _ver_in="$FWU_VER_LATEST"
    fi
    if ! printf '%s\n' "$FWU_VERSIONS_AVAILABLE" | grep -Fxq "$_ver_in"; then
        printf '%s\n' "  Version \"${_ver_in}\" not in list; using latest (${FWU_VER_LATEST})."
        _ver_in="$FWU_VER_LATEST"
    fi
    FWU_FW_VERSION_CHOSEN="$_ver_in"

    fwu_maybe_upgrade_plugin_for_chosen_firmware

    lookup_firmware_recommendation "$FWU_FW_VERSION_CHOSEN"

    if [[ "$FWU_REC_NO_MATCH" == 1 ]]; then
        echo ""
        if [[ "${FWU_REC_PLUGIN_BLOCKED:-0}" == 1 ]]; then
            printf '%s\n' "  Firmware ${FWU_FW_VERSION_CHOSEN} still needs cartographer3d-plugin ${FWU_REC_NEED_PLUGIN:-?} or newer (see min_plugin_version in firmware_list.csv)."
            printf '%s\n' "  Your Klipper env reports: ${FWU_REC_HAVE_PLUGIN:-unknown}"
            printf '%s\n' "  Try: ~/klippy-env/bin/pip install --upgrade cartographer3d-plugin"
            printf '%s\n' "  Check: ~/klippy-env/bin/pip list | grep cartographer3d-plugin"
        else
            printf '%s\n' "  No firmware row for version ${FWU_FW_VERSION_CHOSEN}; check firmware_list.csv."
        fi
        echo ""
        return 0
    fi

    clear 2>/dev/null || true
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    printf '%s|%s%s%s%s|%s\n' "$accent" "$bold" "$(_fwu_center_line 'Firmware recommendation')" "$reset" "$accent" "$reset"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"

    if [[ "$FWU_PROTOCOL" == "CAN" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  Protocol: CAN @ ${FWU_CAN_SPEED} baud, interface: ${FWU_CAN_INTERFACE}")" "$reset"
    else
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Protocol: USB')" "$reset"
    fi
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  Probe: ${DETECTED_PROBE}   Firmware version: ${FWU_REC_VERSION}")" "$reset"
    if [[ -t 1 ]]; then
        if [[ -n "${CURRENTFW:-}" ]]; then
            _fwu_box_row "$accent" "$reset" "  Current firmware (running): ${red}${CURRENTFW}${reset}"
        else
            _fwu_box_row "$accent" "$reset" "  Current firmware (running): not reported"
        fi
    else
        if [[ -n "${CURRENTFW:-}" ]]; then
            printf '%s\n' "  Current firmware (running): ${CURRENTFW}"
        else
            printf '%s\n' "  Current firmware (running): not reported"
        fi
    fi
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"

    if [[ "$FWU_REC_HAS_FULL" == 1 ]]; then
        _fwu_box_row "$accent" "$reset" "${body}  Full build (default):"
        _fwu_box_row "$accent" "$reset" "${body}    ${val_hl}$(_fwu_trunc "${FWU_REC_FULL_FILE}" $((_BOX_INNER - 4)))${reset}"
    fi
    if [[ "$FWU_REC_HAS_LITE" == 1 ]]; then
        _fwu_box_row "$accent" "$reset" "${body}  Lite build:"
        _fwu_box_row "$accent" "$reset" "${body}    ${val_hl}$(_fwu_trunc "${FWU_REC_LITE_FILE}" $((_BOX_INNER - 4)))${reset}"
    fi
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Lite is for slower hosts: Raspberry Pi 2 class SBCs, or host MCUs')" "$reset"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  such as Creality K1 / Qidi, where Full can overload the bus or CPU.')" "$reset"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"

    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    echo ""

    if [[ "$FWU_REC_HAS_FULL" == 1 && "$FWU_REC_HAS_LITE" == 1 ]]; then
        prompt_full_or_lite || true
    elif [[ "$FWU_REC_HAS_FULL" == 1 ]]; then
        FWU_FW_SELECTED_KIND="full"
        FWU_FW_SELECTED_PATH="${FWU_REC_FULL_PATH}"
        FWU_FW_SELECTED_FILE="${FWU_REC_FULL_FILE}"
        printf '%s\n' "  (Only a Full build exists for this probe, link, and version.)"
    elif [[ "$FWU_REC_HAS_LITE" == 1 ]]; then
        FWU_FW_SELECTED_KIND="lite"
        FWU_FW_SELECTED_PATH="${FWU_REC_LITE_PATH}"
        FWU_FW_SELECTED_FILE="${FWU_REC_LITE_FILE}"
        printf '%s\n' "  (Only a Lite-class build is listed for this combo.)"
    fi

    if [[ -n "${FWU_FW_SELECTED_FILE:-}" ]]; then
        echo ""
        printf '%s\n' "  Selected: ${FWU_FW_SELECTED_KIND}  ->  ${FWU_FW_SELECTED_FILE}"
        printf '%s\n' "  Relative path under firmware/: ${FWU_FW_SELECTED_PATH}"
        if [[ "$FWU_PROTOCOL" == "CAN" ]]; then
            printf '%s\n' "  CAN interface for flashing: ${FWU_CAN_INTERFACE}"
        fi
    fi
    echo ""
}

# After firmware recommendation: recap selections before flash_can (only when a file was chosen).
show_flash_selection_summary() {
    local bold reset accent line _pv _build _fv _from _to red
    case "${DETECTED_PROBE:-unknown}" in
        v3) _pv="V3" ;;
        v4) _pv="V4" ;;
        *) _pv="Unknown" ;;
    esac
    case "${FWU_FW_SELECTED_KIND:-}" in
        full) _build="Full" ;;
        lite) _build="Lite" ;;
        *) _build="${FWU_FW_SELECTED_KIND:-}" ;;
    esac
    _fv="${FWU_FW_VERSION_CHOSEN:-${FWU_REC_VERSION:-}}"
    [[ -z "$_fv" ]] && _fv="unknown"
    _from="${CURRENTFW:-unknown}"
    _to="${_fv}"

    if [[ -t 1 ]]; then
        bold=$(tput bold 2>/dev/null || true)
        reset=$(tput sgr0 2>/dev/null || true)
        accent=$(tput setaf 6 2>/dev/null || true)
        red=$(tput setaf 1 2>/dev/null || true)
        line="$(printf '%*s' "$_BOX_INNER" '' | tr ' ' '-')"
        clear 2>/dev/null || true
        printf '%s+%s+%s\n' "$accent" "$line" "$reset"
        printf '%s|%s%s%s%s|%s\n' "$accent" "$bold" "$(_fwu_center_line 'Your selections')" "$reset" "$accent" "$reset"
        printf '%s+%s+%s\n' "$accent" "$line" "$reset"
        _fwu_box_row "$accent" "$reset" "  ${accent}Flashing from ${red}${_from}${reset}${accent} to ${red}${_to}${reset}"
        _fwu_box_row "$accent" "$reset" ""
        _fwu_box_row "$accent" "$reset" "  Probe version:      ${_pv}"
        _fwu_box_row "$accent" "$reset" "  Firmware version:   ${_fv}"
        if [[ "${FWU_PROTOCOL:-}" == "CAN" ]]; then
            _fwu_box_row "$accent" "$reset" "  Protocol:           CAN @ ${FWU_CAN_SPEED:-?} baud"
            if [[ "${FWU_CAN_SPEED_ASSUMED:-}" == "yes" ]]; then
                _fwu_box_row "$accent" "$reset" "  Baud rate assumed (Moonraker did not report CANBUS_FREQUENCY; using 1000000.)"
            fi
        else
            _fwu_box_row "$accent" "$reset" "  Protocol:           USB"
        fi
        _fwu_box_row "$accent" "$reset" "  Build:              ${_build}"
        _fwu_box_row "$accent" "$reset" ""
        _fwu_box_row "$accent" "$reset" "${bold}  Recovery${reset}"
        _fwu_box_row "$accent" "$reset" "  If the wrong firmware image is flashed, recovery is almost always possible by"
        _fwu_box_row "$accent" "$reset" "  entering DFU mode and reflashing the correct file. Entering DFU can be awkward on"
        _fwu_box_row "$accent" "$reset" "  some boards and may take several attempts; you will need a USB cable between this"
        _fwu_box_row "$accent" "$reset" "  host and the probe."
        printf '%s+%s+%s\n' "$accent" "$line" "$reset"
        echo ""
    else
        printf '%s\n' "  Your selections:"
        printf '%s\n' "  Flashing from ${_from} to ${_to}"
        printf '%s\n' ""
        printf '%s\n' "    Probe version:      ${_pv}"
        printf '%s\n' "    Firmware version:   ${_fv}"
        if [[ "${FWU_PROTOCOL:-}" == "CAN" ]]; then
            printf '%s\n' "    Protocol:           CAN @ ${FWU_CAN_SPEED:-?} baud"
            if [[ "${FWU_CAN_SPEED_ASSUMED:-}" == "yes" ]]; then
                printf '%s\n' "    Baud rate assumed (Moonraker did not report CANBUS_FREQUENCY; using 1000000.)"
            fi
        else
            printf '%s\n' "    Protocol:           USB"
        fi
        printf '%s\n' "    Build:              ${_build}"
        printf '%s\n' ""
        printf '%s\n' "  Recovery: If the wrong firmware is flashed, recovery is almost always possible in DFU"
        printf '%s\n' "  mode with the correct file. Entering DFU can be awkward on some boards and may take"
        printf '%s\n' "  several attempts; you need a USB cable between this host and the probe."
        echo ""
    fi
}

show_welcome() {
    local bold reset accent
    if [[ -t 1 ]]; then
        bold=$(tput bold 2>/dev/null || true)
        reset=$(tput sgr0 2>/dev/null || true)
        accent=$(tput setaf 6 2>/dev/null || true)
    else
        bold="" reset="" accent=""
    fi

    local line
    # ASCII box only - UTF-8 line-drawing chars break on C/POSIX locale or serial consoles
    line="$(printf '%*s' "$_BOX_INNER" '' | tr ' ' '-')"

    clear 2>/dev/null || true

    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    printf '%s|%s%s%s%s|%s\n' "$accent" "$bold" "$(_fwu_center_line 'Welcome to the Cartographer3D Update Script')" "$reset" "$accent" "$reset"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  This process updates firmware on your Cartographer probe.')" "$reset"
    printf '%s|%s%s%s%s|%s\n' "$accent" "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Please read each screen fully and follow the instructions.')" "$reset" "$accent" "$reset"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    echo ""
}

show_probe_detection() {
    local bold reset accent
    if [[ -t 1 ]]; then
        bold=$(tput bold 2>/dev/null || true)
        reset=$(tput sgr0 2>/dev/null || true)
        accent=$(tput setaf 6 2>/dev/null || true)
    else
        bold="" reset="" accent=""
    fi

    local line msg1 msg2 msg3
    line="$(printf '%*s' "$_BOX_INNER" '' | tr ' ' '-')"

    clear 2>/dev/null || true

    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    printf '%s|%s%s%s%s|%s\n' "$accent" "$bold" "$(_fwu_center_line 'Detecting your probe')" "$reset" "$accent" "$reset"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"

    [[ -z "${FWU_KLIPPY_LOG_FOUND:-}" ]] && FWU_KLIPPY_LOG_FOUND="no"
    [[ -z "${FWU_MCU_SECTION_FOUND:-}" ]] && FWU_MCU_SECTION_FOUND="no"

    if [[ "$FWU_KLIPPY_LOG_FOUND" == yes ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Klippy log: found')" "$reset"
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  $(_fwu_trunc "${FWU_KLIPPY_LOG_PATH:-}" $((_BOX_INNER - 2)))")" "$reset"
    else
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Klippy log: not found')" "$reset"
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  (searched under $HOME, printer_data/logs, ...)')" "$reset"
    fi

    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"

    if [[ "$FWU_MCU_SECTION_FOUND" == yes ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  [mcu cartographer] / [mcu scanner]: found')" "$reset"
        local _mf _nmore
        _mf="$(printf '%s\n' "${FWU_MCU_SECTION_FILES:-}" | head -1)"
        _nmore="$(printf '%s\n' "${FWU_MCU_SECTION_FILES:-}" | sed '/^$/d' | wc -l | tr -d ' ')"
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  $(_fwu_trunc "$_mf" $((_BOX_INNER - 2)))")" "$reset"
        if [[ "${_nmore:-0}" -gt 1 ]]; then
            printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  (+ $((_nmore - 1)) more file(s))")" "$reset"
        fi
    else
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  [mcu cartographer] / [mcu scanner]: not found')" "$reset"
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  (in scanned klippy.log + config files)')" "$reset"
    fi

    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"

    if [[ -n "${CARTO_CANBUS:-}" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  Parsed canbus_uuid: $(_fwu_trunc "${CARTO_CANBUS}" $((_BOX_INNER - 22)))")" "$reset"
    fi
    if [[ -n "${CARTO_SERIAL:-}" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  Parsed serial: $(_fwu_trunc "${CARTO_SERIAL}" $((_BOX_INNER - 18)))")" "$reset"
    fi
    if [[ -n "${CARTO_CANBUS:-}" || -n "${CARTO_SERIAL:-}" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
    fi

    if [[ -n "${CARTO_CANBUS:-}" && -n "${FWU_CANBUS_FREQUENCY:-}" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  CAN bus frequency (from Moonraker): ${FWU_CANBUS_FREQUENCY} Hz")" "$reset"
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
    fi

    if [[ "${FWU_PROTOCOL:-}" == "CAN" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "  Link for firmware lookup: CAN @ ${FWU_CAN_SPEED:-?} baud")" "$reset"
        if [[ "${FWU_CAN_SPEED_ASSUMED:-}" == yes ]]; then
            printf '%s|%s%s%s%s|%s\n' "$accent" "$accent" "$(printf '%-*s' "$_BOX_INNER" '  (Moonraker did not report CANBUS_FREQUENCY; using 1000000.)')" "$reset" "$accent" "$reset"
        fi
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
    elif [[ "${FWU_PROTOCOL:-}" == "USB" ]]; then
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '  Link for firmware lookup: USB')" "$reset"
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
    fi

    case "$DETECTED_PROBE" in
        v4)
            msg1="  V4 detected."
            case "${FWU_V4_VIA:-}" in
                moonraker)
                    msg2="  Moonraker reports stm32g431 (typical for V4 on CAN)."
                    ;;
                api_uuid)
                    msg2=""
                    ;;
                api_usb|api)
                    msg2="  Cartographer3D API confirmed this USB device."
                    ;;
                *)
                    msg2="  Cartographer3D API confirmed registration."
                    ;;
            esac
            msg3=""
            ;;
        v3)
            msg1="  V3 detected."
            msg2="  Moonraker reports MCU stm32f042x6 for [mcu cartographer]."
            msg3=""
            ;;
        *)
            msg1="  Could not determine probe type automatically."
            msg2="  Check that klippy.log lists [mcu cartographer] or [mcu"
            msg3="  scanner], and Moonraker is reachable for USB probes."
            ;;
    esac

    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" "$msg1")" "$reset"
    if [[ -n "${msg2:-}" ]]; then
        printf '%s|%s%s%s%s|%s\n' "$accent" "$accent" "$(printf '%-*s' "$_BOX_INNER" "$msg2")" "$reset" "$accent" "$reset"
    fi
    if [[ -n "$msg3" ]]; then
        printf '%s|%s%s%s%s|%s\n' "$accent" "$accent" "$(printf '%-*s' "$_BOX_INNER" "$msg3")" "$reset" "$accent" "$reset"
    else
        printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
    fi
    printf '%s|%s|%s\n' "$accent" "$(printf '%-*s' "$_BOX_INNER" '')" "$reset"
    printf '%s+%s+%s\n' "$accent" "$line" "$reset"
    echo ""
}

# Sets FWU_REPORT_* for preview and upload (returns 0 if a report can be sent)
_fwu_compute_report_fields() {
    FWU_REPORT_PROTOCOL="${FWU_PROTOCOL:-}"
    FWU_REPORT_IDENTIFIER=""
    FWU_REPORT_FIRMWARE=""
    FWU_REPORT_FLAVOUR=""
    FWU_REPORT_BAUD=""
    FWU_REPORT_PROBE_VERSION="${DETECTED_PROBE:-unknown}"
    case "$FWU_REPORT_PROBE_VERSION" in
        v3 | v4) ;;
        *) FWU_REPORT_PROBE_VERSION="unknown" ;;
    esac

    if [[ "$FWU_REPORT_PROTOCOL" != "USB" && "$FWU_REPORT_PROTOCOL" != "CAN" ]]; then
        return 1
    fi

    if [[ "$FWU_REPORT_PROTOCOL" == "CAN" ]]; then
        FWU_REPORT_IDENTIFIER="$(_fwu_canbus_uuid_for_flash "${CARTO_CANBUS:-}")"
    else
        FWU_REPORT_IDENTIFIER="$(device_name_from_serial_path "${CARTO_SERIAL:-}")"
    fi
    [[ -n "$FWU_REPORT_IDENTIFIER" ]] || return 1

    FWU_REPORT_FIRMWARE="${FWU_FW_VERSION_CHOSEN:-${FWU_REC_VERSION:-}}"
    [[ -n "$FWU_REPORT_FIRMWARE" ]] || FWU_REPORT_FIRMWARE="unknown"

    case "${FWU_FW_SELECTED_KIND:-full}" in
        lite) FWU_REPORT_FLAVOUR="Lite" ;;
        full | *) FWU_REPORT_FLAVOUR="Full" ;;
    esac

    if [[ "$FWU_REPORT_PROTOCOL" == "CAN" ]]; then
        FWU_REPORT_BAUD="${FWU_CAN_SPEED:-${FWU_CANBUS_FREQUENCY:-}}"
    fi
    return 0
}

# Upload using FWU_REPORT_* (caller must run _fwu_compute_report_fields first)
_fwu_send_usage_report_without_recompute() {
    local -a _curl_args
    _curl_args=(
        -sS -f -G "${_FWU_REPORT_BASE}"
        --data-urlencode "protocol=${FWU_REPORT_PROTOCOL}"
        --data-urlencode "identifier=${FWU_REPORT_IDENTIFIER}"
        --data-urlencode "firmware=${FWU_REPORT_FIRMWARE}"
        --data-urlencode "flavour=${FWU_REPORT_FLAVOUR}"
        --data-urlencode "probe_version=${FWU_REPORT_PROBE_VERSION}"
    )
    if [[ "$FWU_REPORT_PROTOCOL" == "CAN" && -n "$FWU_REPORT_BAUD" ]]; then
        _curl_args+=(--data-urlencode "baudrate=${FWU_REPORT_BAUD}")
    fi

    if ! curl "${_curl_args[@]}" -o /dev/null; then
        printf '%s\n' "  Anonymous report could not be sent (network or server error)." >&2
        return 1
    fi
    printf '%s\n' "  Anonymous usage report sent, THANK YOU!"
    return 0
}

# Standalone: compute fields then upload
_fwu_send_usage_report() {
    if ! _fwu_compute_report_fields; then
        printf '%s\n' "  (Cannot send report: missing USB/CAN link or identifier.)" >&2
        return 1
    fi
    _fwu_send_usage_report_without_recompute
}

# After firmware update: thanks + optional anonymous stats (no PII)
show_thanks_and_optional_stats() {
    local bold reset accent body white val_hl _choice _line
    if [[ -t 1 ]]; then
        bold=$(tput bold 2>/dev/null || true)
        reset=$(tput sgr0 2>/dev/null || true)
        accent=$(tput setaf 6 2>/dev/null || true)
        body="${accent}"
        white=$(tput setaf 7 2>/dev/null || true)
        val_hl="${bold}${white}"
    else
        bold="" reset="" accent="" body="" white="" val_hl=""
    fi

    clear 2>/dev/null || true

    if ! _fwu_compute_report_fields; then
        if [[ -t 1 ]]; then
            _fwu_print_thanks_box_simple "$bold" "$reset" "$accent" "$body"
            echo ""
            printf '%s%s%s\n' "$body" "  No anonymous report is available (need USB or CAN with serial / canbus_uuid from config)." "$reset"
        else
            printf '%s\n' "  Thank you for updating your Cartographer probe firmware."
            printf '%s\n' "  No anonymous report is available (need USB or CAN with serial / canbus_uuid from config)."
        fi
        echo ""
        return 0
    fi

    if [[ -t 1 ]]; then
        while true; do
            clear 2>/dev/null || true
            _fwu_print_thanks_box_with_report "$bold" "$reset" "$accent" "$body" "$val_hl"
            echo ""
            printf '%s\n' "  Send anonymous report:"
            printf '%s\n' "    1 - Send the report above"
            printf '%s\n' "    2 - Do not send"
            if [[ -r /dev/tty ]]; then
                read -r -p "  Enter 1 or 2: " _line </dev/tty || true
            else
                read -r -p "  Enter 1 or 2: " _line || true
            fi
            _line="$(printf '%s' "$_line" | tr -d '[:space:]')"
            [[ -z "$_line" ]] && continue
            case "$_line" in
                1) _choice=yes; break ;;
                2) _choice=no; break ;;
                *) continue ;;
            esac
        done
    else
        printf '%s\n' "  Thank you for updating your Cartographer probe firmware."
        _fwu_print_report_summary_plain
        printf '%s\n' "  Send anonymous report:"
        printf '%s\n' "    1 - Send the report above"
        printf '%s\n' "    2 - Do not send"
        read -r -p "  Enter 1 or 2: " _line || true
        _line="$(printf '%s' "$_line" | tr -d '[:space:]')"
        case "$_line" in
            1) _choice=yes ;;
            *) _choice=no ;;
        esac
    fi

    case "$_choice" in
        yes)
            set +e
            _fwu_send_usage_report_without_recompute
            set -e
            ;;
        no)
            printf '%s\n' "  Report not sent (you opted out)."
            ;;
    esac
    echo ""
}

main() {
    show_welcome
    read -r -p "Press Enter to continue... "

    set +e
    detect_probe
    set -e

    set_fwu_protocol_and_can

    show_probe_detection
    read -r -p "Press Enter to continue... "

    show_firmware_recommendation
    read -r -p "Press Enter to continue... "

    if [[ -n "${FWU_FW_SELECTED_PATH:-}" ]]; then
        show_flash_selection_summary
        local _dflash _flash_exit
        read -r -p "Run Klipper flash_can.py now with the selected firmware? [Y/n] " _dflash || true
        _dflash="${_dflash:-y}"
        _dflash="$(printf '%s' "$_dflash" | tr '[:upper:]' '[:lower:]')"
        if [[ "$_dflash" != n* ]]; then
            local _read_ack
            echo ""
            read -r -p "Did you read the above information? [Y/n] " _read_ack || true
            _read_ack="${_read_ack:-y}"
            _read_ack="$(printf '%s' "$_read_ack" | tr '[:upper:]' '[:lower:]')"
            if [[ "$_read_ack" != n* ]]; then
                set +e
                perform_firmware_flash
                _flash_exit=$?
                set -e
                if [[ "$_flash_exit" -ne 0 ]]; then
                    printf '%s\n' "Flashing exited with status ${_flash_exit}."
                fi
            else
                printf '%s\n' "  Skipping flash (you indicated you had not read the information above)."
            fi
        fi
    fi

    show_thanks_and_optional_stats
}

main "$@"
