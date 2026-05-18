#!/usr/bin/env bash

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# ============================================================
# LabDroid Gateway
# Android Lab Edge Controller
#
# PRODUCT BOUNDARY:
# - Chỉ scan/connect TCP port 5555.
# - Không có custom port.
# - Không nhận port từ người dùng.
# - Dành cho Android lab devices đã bật ADB Wi-Fi.
# ============================================================

ADB_PORT=5555
ADB_BIN="${ADB_BIN:-adb}"

APP_DIR="$HOME/.labdroid"
CACHE_DIR="$APP_DIR/cache"
TMP_DIR="$APP_DIR/tmp"
DEVICE_FILE="$APP_DIR/devices.txt"
NAME_FILE="$APP_DIR/names.txt"
LAST_FILE="$APP_DIR/last_file.txt"
UPLOAD_WEB_URL="https://thong-url-1.onrender.com"

SCAN_CONCURRENCY=64
ADB_CONCURRENCY=24
VIDEO_SCAN_CONCURRENCY=12
VIDEO_DIRS="/sdcard/Download /storage/emulated/0/Download /sdcard/DCIM /sdcard/DCIM/Camera /sdcard/Movies /sdcard/Pictures"

mkdir -p "$APP_DIR" "$CACHE_DIR" "$TMP_DIR"
touch "$DEVICE_FILE" "$NAME_FILE" "$LAST_FILE"

ESC=$'\033'
RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"

BRIGHT_RED="${ESC}[91m"
BRIGHT_GREEN="${ESC}[92m"
BRIGHT_YELLOW="${ESC}[93m"
BRIGHT_BLUE="${ESC}[94m"
BRIGHT_MAGENTA="${ESC}[95m"
BRIGHT_CYAN="${ESC}[96m"
BRIGHT_WHITE="${ESC}[97m"

COLORS=(
  "$BRIGHT_RED"
  "$BRIGHT_YELLOW"
  "$BRIGHT_GREEN"
  "$BRIGHT_CYAN"
  "$BRIGHT_BLUE"
  "$BRIGHT_MAGENTA"
)

pause_enter() {
  echo ""
  printf "%bNhấn Enter để tiếp tục...%b" "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r _
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ui_ok() {
  printf "%b%s%b\n" "$BRIGHT_GREEN$BOLD" "$1" "$RESET"
}

ui_warn() {
  printf "%b%s%b\n" "$BRIGHT_YELLOW$BOLD" "$1" "$RESET"
}

ui_err() {
  printf "%b%s%b\n" "$BRIGHT_RED$BOLD" "$1" "$RESET"
}

ui_info() {
  printf "%b%s%b\n" "$BRIGHT_CYAN$BOLD" "$1" "$RESET"
}

ui_dim() {
  printf "%b%s%b\n" "$DIM$BRIGHT_WHITE" "$1" "$RESET"
}

rand_color() {
  local idx=$((RANDOM % ${#COLORS[@]}))
  printf "%b" "${COLORS[$idx]}"
}

ui_line() {
  local color
  color=$(rand_color)
  printf "%b=======================================================%b\n" "$color$BOLD" "$RESET"
}

gradient_text() {
  local text="$1"
  local i char idx total
  total=${#COLORS[@]}

  for ((i=0; i<${#text}; i++)); do
    char="${text:$i:1}"
    idx=$((i % total))
    printf "%b%s%b" "${COLORS[$idx]}$BOLD" "$char" "$RESET"
  done
}

ui_title() {
  clear
  ui_line
  printf "   "
  gradient_text "LabDroid Gateway - Android Lab Edge Controller"
  printf "\n"
  printf "   %bADB Wi-Fi fixed port:%b %b%s%b\n" "$BRIGHT_YELLOW$BOLD" "$RESET" "$BRIGHT_GREEN$BOLD" "$ADB_PORT" "$RESET"
  ui_line
}

detect_env() {
  if [ -n "$TERMUX_VERSION" ] || echo "$PREFIX" | grep -qi "com.termux"; then
    echo "termux"
  elif [ -f /etc/alpine-release ]; then
    echo "alpine"
  elif has_cmd apt; then
    echo "debian"
  elif has_cmd apk; then
    echo "alpine"
  else
    echo "unknown"
  fi
}

auto_install_missing() {
  local missing=""
  local env_type

  for c in bash adb timeout awk grep sed sort wc seq curl; do
    if ! has_cmd "$c"; then
      missing="$missing $c"
    fi
  done

  if [ -z "$missing" ]; then
    return
  fi

  ui_title
  ui_warn "Thiếu addon:$missing"
  ui_warn "Đang thử tự cài addon cần thiết..."
  echo ""

  env_type="$(detect_env)"

  case "$env_type" in
    termux)
      pkg update -y
      pkg install -y bash android-tools coreutils grep gawk sed curl wget iproute2 nano
      ;;
    alpine)
      apk update || true
      apk add bash android-tools coreutils grep gawk sed curl wget iproute2 nano
      ;;
    debian)
      sudo apt update -y || apt update -y || true
      sudo apt install -y bash android-tools-adb coreutils grep gawk sed curl wget iproute2 nano || \
      apt install -y bash android-tools-adb coreutils grep gawk sed curl wget iproute2 nano
      ;;
    *)
      ui_err "Không tự cài được vì không nhận diện được hệ thống."
      echo "Hãy đảm bảo môi trường có: bash, adb, timeout, awk, grep, sed, curl/wget."
      pause_enter
      ;;
  esac
}

normalize_serial() {
  local s="$1"
  local ip_only

  s="$(echo "$s" | tr -d ' ')"

  if [ -z "$s" ]; then
    echo ""
    return
  fi

  ip_only="${s%%:*}"
  echo "$ip_only:$ADB_PORT"
}

safe_filename() {
  local name="$1"
  name="$(printf "%s" "$name" | tr -cd 'A-Za-z0-9._-')"
  [ -z "$name" ] && name="video_$(date +%Y%m%d_%H%M%S).mp4"
  echo "$name"
}

get_name_by_ip() {
  local serial="$1"
  local name

  name=$(grep -F "|$serial" "$NAME_FILE" 2>/dev/null | head -n 1 | cut -d'|' -f1)

  if [ -n "$name" ]; then
    echo "$name"
  else
    echo "$serial"
  fi
}

save_device() {
  local serial="$1"

  serial="$(normalize_serial "$serial")"
  [ -z "$serial" ] && return

  echo "$serial" >> "$DEVICE_FILE"
  sort -u "$DEVICE_FILE" -o "$DEVICE_FILE"
}

adb_start_clean() {
  $ADB_BIN start-server >/dev/null 2>&1
}

list_connected_devices_raw() {
  $ADB_BIN devices 2>/dev/null | awk -v p=":$ADB_PORT" 'NR>1 && $2=="device" && $1 ~ p"$" {print $1}' | sort -u
}

connected_count() {
  list_connected_devices_raw | wc -l | tr -d ' '
}

check_adb_port_5555() {
  local ip="$1"
  timeout 1 bash -c "echo >/dev/tcp/$ip/$ADB_PORT" >/dev/null 2>&1
}

clear_video_scan_cache() {
  rm -f "$TMP_DIR"/video_votes.txt \
        "$TMP_DIR"/video_map.txt \
        "$TMP_DIR"/all_videos_list.txt \
        "$TMP_DIR"/all_video_count.txt \
        "$TMP_DIR"/video_devices.txt \
        "$TMP_DIR"/videos_*.txt \
        "$TMP_DIR"/vote_*.txt \
        "$TMP_DIR"/map_*.txt 2>/dev/null
}

verify_video_on_device() {
  local dev="$1"
  local video="$2"

  $ADB_BIN -s "$dev" shell "
    for d in /sdcard/Download /storage/emulated/0/Download /sdcard/DCIM /sdcard/DCIM/Camera /sdcard/Movies /sdcard/Pictures; do
      [ -f \"\$d/$video\" ] && exit 0
    done
    exit 1
  " >/dev/null 2>&1
}

list_connected_devices_named() {
  local devices
  local i
  local dev
  local name
  local brand
  local model
  local battery

  devices=$(list_connected_devices_raw)

  if [ -z "$devices" ]; then
    ui_warn "Không có thiết bị nào đang connect port $ADB_PORT."
    return
  fi

  i=1

  while IFS= read -r dev; do
    [ -z "$dev" ] && continue

    name=$(get_name_by_ip "$dev")
    brand="$($ADB_BIN -s "$dev" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
    model="$($ADB_BIN -s "$dev" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
    battery="$($ADB_BIN -s "$dev" shell dumpsys battery 2>/dev/null | awk -F': ' '/level/ {print $2; exit}' | tr -d '\r')"

    printf "%b%s)%b %b%s%b %b(%s)%b | %s %s | Pin: %s%%\n" \
      "$BRIGHT_WHITE$BOLD" "$i" "$RESET" \
      "$BRIGHT_GREEN$BOLD" "$name" "$RESET" \
      "$DIM$BRIGHT_WHITE" "$dev" "$RESET" \
      "${brand:-?}" "${model:-?}" "${battery:-?}"

    i=$((i + 1))
  done <<EOF
$devices
EOF
}

choose_devices() {
  local devices
  local line
  local i
  local choice
  local idx
  local dev
  local name

  devices=$(list_connected_devices_raw)

  if [ -z "$devices" ]; then
    ui_err "Không có thiết bị nào đang connect port $ADB_PORT."
    return 1
  fi

  DEV_ARR=()

  while IFS= read -r line; do
    [ -n "$line" ] && DEV_ARR+=("$line")
  done <<EOF
$devices
EOF

  echo ""
  ui_line
  ui_info "Danh sách thiết bị đang connect:"
  echo ""

  i=1
  for dev in "${DEV_ARR[@]}"; do
    [ -z "$dev" ] && continue
    name=$(get_name_by_ip "$dev")

    printf "%b%s)%b %b%s%b %b(%s)%b\n" \
      "$BRIGHT_WHITE$BOLD" "$i" "$RESET" \
      "$BRIGHT_GREEN$BOLD" "$name" "$RESET" \
      "$DIM$BRIGHT_WHITE" "$dev" "$RESET"

    i=$((i + 1))
  done

  echo ""
  ui_dim "Cách chọn:"
  printf "%ball%b    -> chọn tất cả\n" "$BRIGHT_CYAN$BOLD" "$RESET"
  printf "%b1%b      -> chọn máy số 1\n" "$BRIGHT_CYAN$BOLD" "$RESET"
  printf "%b1 2 5%b  -> chọn nhiều máy theo số\n" "$BRIGHT_CYAN$BOLD" "$RESET"
  echo ""
  printf "%bChọn thiết bị:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r choice

  SELECTED_DEVICES=()

  if [ -z "$choice" ] || [ "$choice" = "all" ] || [ "$choice" = "a" ] || [ "$choice" = "tatca" ]; then
    for dev in "${DEV_ARR[@]}"; do
      [ -n "$dev" ] && SELECTED_DEVICES+=("$dev")
    done
  else
    for idx in $choice; do
      case "$idx" in
        ''|*[!0-9]*)
          ;;
        *)
          if [ "$idx" -ge 1 ] && [ "$idx" -le "${#DEV_ARR[@]}" ]; then
            SELECTED_DEVICES+=("${DEV_ARR[$((idx - 1))]}")
          fi
          ;;
      esac
    done
  fi

  if [ "${#SELECTED_DEVICES[@]}" -eq 0 ]; then
    ui_err "Chưa chọn thiết bị hợp lệ."
    return 1
  fi

  return 0
}

adb_connect_twice() {
  local serial="$1"

  serial="$(normalize_serial "$serial")"
  [ -z "$serial" ] && return 1

  $ADB_BIN connect "$serial" >/dev/null 2>&1
  sleep 1
  $ADB_BIN connect "$serial" >/dev/null 2>&1

  if $ADB_BIN devices | grep -q "^$serial[[:space:]]*device$"; then
    ui_ok "OK   $serial"
    save_device "$serial"
    return 0
  else
    ui_err "FAIL $serial"
    return 1
  fi
}

scan_and_connect_subnet() {
  local subnets
  local subnet
  local i
  local ip
  local serial

  ui_title
  ui_info "Scan subnet và connect thiết bị Android lab port $ADB_PORT"
  ui_line
  echo "Ví dụ:"
  echo "10.48.154"
  echo "10.48.154 10.48.155"
  echo "192.168.1"
  echo ""
  printf "%bNhập subnet:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r subnets

  if [ -z "$subnets" ]; then
    ui_err "Chưa nhập subnet."
    return
  fi

  : > "$DEVICE_FILE"

  echo ""
  ui_info "Đang scan port $ADB_PORT và connect 2 lần..."
  echo ""

  for subnet in $subnets; do
    for i in $(seq 1 254); do
      ip="$subnet.$i"

      (
        if check_adb_port_5555 "$ip"; then
          serial="$ip:$ADB_PORT"
          echo "$serial" >> "$DEVICE_FILE"
          printf "%bOPEN%b %s\n" "$BRIGHT_GREEN$BOLD" "$RESET" "$serial"

          $ADB_BIN connect "$serial" >/dev/null 2>&1
          sleep 1
          $ADB_BIN connect "$serial" >/dev/null 2>&1

          if $ADB_BIN devices | grep -q "^$serial[[:space:]]*device$"; then
            printf "%bOK%b   %s\n" "$BRIGHT_CYAN$BOLD" "$RESET" "$serial"
          else
            printf "%bFAIL%b %s\n" "$BRIGHT_RED$BOLD" "$RESET" "$serial"
          fi
        fi
      ) &

      while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$SCAN_CONCURRENCY" ]; do
        sleep 0.02
      done
    done
  done

  wait
  sort -u "$DEVICE_FILE" -o "$DEVICE_FILE"

  echo ""
  ui_ok "Tổng connected: $(connected_count)"
}

quick_scan_154_155() {
  local subnet
  local i
  local ip
  local serial

  ui_title
  ui_info "Scan nhanh 10.48.154.xxx + 10.48.155.xxx port $ADB_PORT"
  ui_line

  : > "$DEVICE_FILE"

  for subnet in 154 155; do
    for i in $(seq 1 254); do
      ip="10.48.$subnet.$i"

      (
        if check_adb_port_5555 "$ip"; then
          serial="$ip:$ADB_PORT"
          echo "$serial" >> "$DEVICE_FILE"
          printf "%bOPEN%b %s\n" "$BRIGHT_GREEN$BOLD" "$RESET" "$serial"

          $ADB_BIN connect "$serial" >/dev/null 2>&1
          sleep 1
          $ADB_BIN connect "$serial" >/dev/null 2>&1

          if $ADB_BIN devices | grep -q "^$serial[[:space:]]*device$"; then
            printf "%bOK%b   %s\n" "$BRIGHT_CYAN$BOLD" "$RESET" "$serial"
          fi
        fi
      ) &
    done
  done

  wait
  sort -u "$DEVICE_FILE" -o "$DEVICE_FILE"

  echo ""
  ui_ok "Tổng connected: $(connected_count)"
}

connect_manual() {
  local ips
  local ip
  local serial

  adb_start_clean

  ui_title
  ui_info "Connect IP thủ công - chỉ port $ADB_PORT"
  ui_line
  echo "Ví dụ:"
  echo "10.48.154.116"
  echo "10.48.154.116 10.48.154.117"
  echo ""
  printf "%bIP cần connect:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r ips

  if [ -z "$ips" ]; then
    ui_err "Chưa nhập IP."
    return
  fi

  for ip in $ips; do
    serial="$(normalize_serial "$ip")"

    adb_connect_twice "$serial" &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$ADB_CONCURRENCY" ]; do
      sleep 0.03
    done
  done

  wait

  echo ""
  ui_ok "Thiết bị đang connect:"
  list_connected_devices_named
}

connect_saved_devices() {
  local serial

  ui_title

  if [ ! -s "$DEVICE_FILE" ]; then
    ui_err "Chưa có danh sách thiết bị đã scan."
    return
  fi

  ui_info "Đang connect lại danh sách đã scan port $ADB_PORT..."
  echo ""

  while IFS= read -r serial; do
    [ -z "$serial" ] && continue
    serial="$(normalize_serial "$serial")"

    adb_connect_twice "$serial" &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$ADB_CONCURRENCY" ]; do
      sleep 0.03
    done
  done < "$DEVICE_FILE"

  wait

  echo ""
  ui_ok "Tổng connected: $(connected_count)"
}

adb_push_with_progress() {
  local serial="$1"
  local src="$2"

  local dst_dir="${3:-/sdcard/Download}"
  adb -s "$serial" shell "mkdir -p '$dst_dir'" >/dev/null 2>&1
  adb -s "$serial" push "$src" "$dst_dir/"
}

adb_pull_with_progress() {
  local serial="$1"
  local src="$2"
  local dst="$3"

  adb -s "$serial" pull "$src" "$dst"
}

push_file_to_selected_devices() {
  local src="$1"
  local name="$2"
  local dev
  local devname
  local ok=0
  local fail=0

  if [ ! -f "$src" ]; then
    ui_err "Không thấy file: $src"
    return 1
  fi

  choose_devices || return 1

  echo ""
  ui_info "Đang push: $name"
  ui_dim "Kiểu push: adb -s SERIAL push FILE /sdcard/Download/"
  echo ""

  for dev in "${SELECTED_DEVICES[@]}"; do
    devname=$(get_name_by_ip "$dev")

    printf "%b→%b %b%s%b %b(%s)%b\n" \
      "$BRIGHT_WHITE$BOLD" "$RESET" \
      "$BRIGHT_GREEN$BOLD" "$devname" "$RESET" \
      "$DIM$BRIGHT_WHITE" "$dev" "$RESET"

    adb_push_with_progress "$dev" "$src"

    if [ $? -eq 0 ]; then
      sleep 0.2
      adb -s "$dev" shell sync >/dev/null 2>&1 || true

      if verify_video_on_device "$dev" "$name"; then
        ui_ok "   PUSH OK + VERIFY OK"
        ok=$((ok + 1))
      else
        ui_warn "   PUSH OK nhưng VERIFY chưa thấy file"
        ok=$((ok + 1))
      fi
    else
      ui_err "   PUSH FAIL"
      fail=$((fail + 1))
    fi

    echo ""
  done

  clear_video_scan_cache

  ui_info "Kết quả push: OK=$ok | FAIL=$fail"
  ui_ok "Đã xoá cache danh sách video. Vào mục 5/6 sẽ quét lại số mới."
}

push_local_file_menu() {
  local last
  local file
  local name

  ui_title
  ui_info "Push file/video lên thiết bị"
  ui_line

  if [ -f "$LAST_FILE" ]; then
    last="$(cat "$LAST_FILE")"
    ui_dim "File lần trước: $last"
  fi

  echo "Ví dụ:"
  echo "/storage/emulated/0/Download/vario.mp4"
  echo "/sdcard/Download/vario.mp4"
  echo ""
  printf "%bĐường dẫn file/video:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r file

  if [ -z "$file" ] && [ -n "$last" ]; then
    file="$last"
  fi

  if [ ! -f "$file" ]; then
    ui_err "Không tìm thấy file: $file"
    return
  fi

  echo "$file" > "$LAST_FILE"
  name="$(basename "$file")"

  push_file_to_selected_devices "$file" "$name"
}

list_videos_on_device() {
  local dev="$1"

  $ADB_BIN -s "$dev" shell '
    for d in /sdcard/Download /storage/emulated/0/Download /sdcard/DCIM /sdcard/DCIM/Camera /sdcard/Movies /sdcard/Pictures; do
      [ -d "$d" ] || continue
      find "$d" -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.m4v" -o -iname "*.3gp" -o -iname "*.webm" \) 2>/dev/null
    done
  ' | tr -d '
' | sed '/^[[:space:]]*$/d' | sort -u
}

build_all_video_list() {
  local vote_file="$TMP_DIR/video_votes.txt"
  local map_file="$TMP_DIR/video_map.txt"
  local list_file="$TMP_DIR/all_videos_list.txt"
  local count_file="$TMP_DIR/all_video_count.txt"
  local device_file="$TMP_DIR/video_devices.txt"
  local total
  local serial
  local safe
  local tmp_each
  local tmp_vote
  local tmp_map
  local v
  local idx
  local have_count

  clear_video_scan_cache

  : > "$vote_file"
  : > "$map_file"
  : > "$list_file"
  : > "$count_file"
  : > "$device_file"

  list_connected_devices_raw > "$device_file"

  if [ ! -s "$device_file" ]; then
    ui_err "Chưa có thiết bị nào đang connect port $ADB_PORT."
    ui_warn "Hãy scan/connect trước rồi thử lại."
    return 1
  fi

  total="$(wc -l < "$device_file" | tr -d ' ')"

  echo ""
  ui_info "Đang quét TƯƠI toàn bộ video trong /sdcard/Download trên $total thiết bị..."
  echo ""

  while read -r serial; do
    [ -z "$serial" ] && continue

    (
      safe="${serial//[:.]/_}"
      tmp_each="$TMP_DIR/videos_${safe}.txt"
      tmp_vote="$TMP_DIR/vote_${safe}.txt"
      tmp_map="$TMP_DIR/map_${safe}.txt"

      : > "$tmp_each"
      : > "$tmp_vote"
      : > "$tmp_map"

      list_videos_on_device "$serial" > "$tmp_each"

      if [ -s "$tmp_each" ]; then
        while read -r v; do
          [ -z "$v" ] && continue
          echo "$v" >> "$tmp_vote"
          echo "$v|$serial" >> "$tmp_map"
        done < "$tmp_each"

        printf "%bDONE%b → %s | %s video\n" \
          "$BRIGHT_GREEN$BOLD" "$RESET" \
          "$(get_name_by_ip "$serial")" \
          "$(wc -l < "$tmp_each" | tr -d ' ')"
      else
        printf "%bEMPTY%b → %s | không thấy video\n" \
          "$BRIGHT_YELLOW$BOLD" "$RESET" \
          "$(get_name_by_ip "$serial")"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$VIDEO_SCAN_CONCURRENCY" ]; do
      sleep 0.05
    done
  done < "$device_file"

  wait

  cat "$TMP_DIR"/vote_*.txt 2>/dev/null > "$vote_file"
  cat "$TMP_DIR"/map_*.txt 2>/dev/null > "$map_file"

  if [ ! -s "$vote_file" ]; then
    echo ""
    ui_err "Không tìm thấy video nào trong /sdcard/Download."
    return 1
  fi

  sort "$vote_file" | uniq -c | sort -nr > "$count_file"
  awk '{$1=""; sub(/^ /,""); print}' "$count_file" > "$list_file"

  echo ""
  ui_line
  ui_info "Danh sách TẤT CẢ video tìm thấy:"
  echo ""

  idx=1

  while read -r v; do
    [ -z "$v" ] && continue

    have_count="$(grep -Fx "$v" "$vote_file" | wc -l | tr -d ' ')"

    printf "%b%s)%b %b%s%b %b[%s/%s máy có]%b\n" \
      "$BRIGHT_WHITE$BOLD" "$idx" "$RESET" \
      "$BRIGHT_GREEN$BOLD" "$v" "$RESET" \
      "$DIM$BRIGHT_WHITE" "$have_count" "$total" "$RESET"

    idx=$((idx + 1))
  done < "$list_file"

  return 0
}

choose_video_from_lab() {
  local n
  local video

  build_all_video_list || return 1

  echo ""
  ui_dim "Cách chọn: nhập số thứ tự video, ví dụ 1 hoặc 2"
  printf "%bChọn video số:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r n

  case "$n" in
    ''|*[!0-9]*)
      ui_err "Lựa chọn không hợp lệ."
      return 1
      ;;
  esac

  video="$(sed -n "${n}p" "$TMP_DIR/all_videos_list.txt")"

  if [ -z "$video" ]; then
    ui_err "Không có video ở số thứ tự này."
    return 1
  fi

  VIDEO_SELECTED="$video"
  return 0
}

find_source_device_from_map() {
  local video="$1"
  local map_file="$TMP_DIR/video_map.txt"

  awk -F'|' -v v="$video" '$1 == v {print $2; exit}' "$map_file"
}

open_lab_video_menu() {
  local video
  local dev

  ui_title
  ui_info "Liệt kê tất cả video trong lab rồi chọn mở"
  ui_line

  choose_video_from_lab || return
  video="$VIDEO_SELECTED"

  echo ""
  ui_ok "Video đã chọn: $video"

  choose_devices || return

  echo ""
  ui_info "Đang mở video trên thiết bị đã chọn..."
  echo ""

  for dev in "${SELECTED_DEVICES[@]}"; do
    [ -z "$dev" ] && continue

    printf "%b→%b %b%s%b %b(%s)%b\n" \
      "$BRIGHT_WHITE$BOLD" "$RESET" \
      "$BRIGHT_GREEN$BOLD" "$(get_name_by_ip "$dev")" "$RESET" \
      "$DIM$BRIGHT_WHITE" "$dev" "$RESET"

    adb -s "$dev" shell am start \
      -a android.intent.action.VIEW \
      -d "file:///sdcard/Download/$video" \
      -t "video/*" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
      ui_ok "   OPEN OK"
    else
      ui_err "   OPEN FAIL"
    fi

    echo ""
  done
}

sync_lab_video_menu() {
  local video
  local source_dev
  local local_file
  local dev
  local skip_have
  local play_now
  local ok=0
  local fail=0
  local skip=0

  ui_title
  ui_info "Liệt kê tất cả video trong lab rồi chọn đồng bộ/push"
  ui_line

  choose_video_from_lab || return
  video="$VIDEO_SELECTED"

  echo ""
  ui_ok "Video đã chọn: $video"

  source_dev="$(find_source_device_from_map "$video")"

  if [ -z "$source_dev" ]; then
    ui_err "Không tìm được máy nguồn trong dữ liệu đã quét."
    return
  fi

  ui_info "Máy nguồn: $(get_name_by_ip "$source_dev") ($source_dev)"

  mkdir -p "$CACHE_DIR"
  local_file="$CACHE_DIR/$video"

  if [ -f "$local_file" ]; then
    ui_warn "Dùng file cache: $local_file"
  else
    echo ""
    ui_info "Đang pull từ máy nguồn về cache..."
    ui_dim "$source_dev:/sdcard/Download/$video"
    ui_dim "$local_file"
    echo ""

    adb_pull_with_progress "$source_dev" "/sdcard/Download/$video" "$local_file"

    if [ $? -ne 0 ] || [ ! -f "$local_file" ]; then
      ui_err "Pull thất bại."
      return
    fi
  fi

  echo ""
  ui_info "Bây giờ chọn thiết bị đích để push video sang."
  choose_devices || return

  echo ""
  printf "%bBỏ qua máy đã có video này? [Y/n]:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r skip_have
  [ -z "$skip_have" ] && skip_have="Y"

  printf "%bPush xong có phát luôn không? [y/N]:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r play_now

  echo ""
  ui_info "Đang push video sang thiết bị đã chọn..."
  ui_dim "Dùng kiểu push ổn định: adb -s SERIAL push FILE /sdcard/Download/"
  echo ""

  for dev in "${SELECTED_DEVICES[@]}"; do
    [ -z "$dev" ] && continue

    printf "%b→%b %b%s%b %b(%s)%b\n" \
      "$BRIGHT_WHITE$BOLD" "$RESET" \
      "$BRIGHT_GREEN$BOLD" "$(get_name_by_ip "$dev")" "$RESET" \
      "$DIM$BRIGHT_WHITE" "$dev" "$RESET"

    if echo "$skip_have" | grep -qi '^y'; then
      if verify_video_on_device "$dev" "$video"; then
        ui_warn "   SKIP đã có"
        skip=$((skip + 1))
        echo ""
        continue
      fi
    fi

    adb_push_with_progress "$dev" "$local_file"

    if [ $? -eq 0 ]; then
      sleep 0.2
      adb -s "$dev" shell sync >/dev/null 2>&1 || true

      if verify_video_on_device "$dev" "$video"; then
        ui_ok "   PUSH OK + VERIFY OK"
      else
        ui_warn "   PUSH OK nhưng VERIFY chưa thấy file"
      fi

      ok=$((ok + 1))

      if echo "$play_now" | grep -qi '^y'; then
        adb -s "$dev" shell am start \
          -a android.intent.action.VIEW \
          -d "file:///sdcard/Download/$video" \
          -t "video/*" >/dev/null 2>&1

        if [ $? -eq 0 ]; then
          ui_ok "   PLAY OK"
        else
          ui_err "   PLAY FAIL"
        fi
      fi
    else
      ui_err "   PUSH FAIL"
      fail=$((fail + 1))
    fi

    echo ""
  done

  clear_video_scan_cache

  ui_info "Kết quả: PUSH_OK=$ok | FAIL=$fail | SKIP=$skip"
  ui_ok "Đã xoá cache danh sách video. Vào mục 5 sẽ thấy số mới."
}

download_url_to_cache_and_push() {
  local url
  local default_name
  local new_name
  local local_file

  ui_title
  ui_info "Tải video từ URL direct vào cache rồi push"
  ui_line

  printf "%bNhập URL direct:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r url

  if [ -z "$url" ]; then
    ui_err "URL trống."
    return
  fi

  default_name="$(basename "${url%%\?*}" | sed 's/%20/ /g')"

  if [ -z "$default_name" ] || ! echo "$default_name" | grep -q '\.'; then
    default_name="video_$(date +%Y%m%d_%H%M%S).mp4"
  fi

  echo ""
  ui_dim "Tên gợi ý: $default_name"
  printf "%bĐổi tên file, Enter để giữ nguyên:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r new_name

  [ -z "$new_name" ] && new_name="$default_name"
  new_name="$(safe_filename "$new_name")"
  local_file="$CACHE_DIR/$new_name"

  echo ""
  ui_info "Đang tải về cache:"
  ui_dim "$local_file"

  if has_cmd curl; then
    curl -L --progress-bar "$url" -o "$local_file"
  elif has_cmd wget; then
    wget -O "$local_file" "$url"
  else
    ui_err "Thiếu curl/wget."
    return
  fi

  if [ $? -ne 0 ] || [ ! -f "$local_file" ]; then
    ui_err "Tải thất bại."
    return
  fi

  echo "$local_file" > "$LAST_FILE"

  echo ""
  ui_ok "Tải xong: $local_file"
  ls -lh "$local_file" 2>/dev/null

  push_file_to_selected_devices "$local_file" "$(basename "$local_file")"
}

open_upload_web() {
  ui_title
  ui_info "Mở web upload video lấy direct URL"
  ui_line
  echo "$UPLOAD_WEB_URL"
  echo ""

  if [ -x /system/bin/am ]; then
    /system/bin/am start -a android.intent.action.VIEW -d "$UPLOAD_WEB_URL" >/dev/null 2>&1 && {
      ui_ok "Đã mở web bằng /system/bin/am"
      return
    }
  fi

  if has_cmd am; then
    am start -a android.intent.action.VIEW -d "$UPLOAD_WEB_URL" >/dev/null 2>&1 && {
      ui_ok "Đã mở web bằng am"
      return
    }
  fi

  if has_cmd termux-open-url; then
    termux-open-url "$UPLOAD_WEB_URL" && {
      ui_ok "Đã mở web bằng termux-open-url"
      return
    }
  fi

  if has_cmd xdg-open; then
    xdg-open "$UPLOAD_WEB_URL" >/dev/null 2>&1 && {
      ui_ok "Đã mở web bằng xdg-open"
      return
    }
  fi

  ui_warn "Không mở tự động được. Copy link trên vào trình duyệt."
}

go_home_selected() {
  local dev
  local ok=0
  local fail=0

  ui_title
  ui_info "Đưa thiết bị đã chọn về Home"
  ui_line

  choose_devices || return

  echo ""
  for dev in "${SELECTED_DEVICES[@]}"; do
    printf "%b→%b %b%s%b %b(%s)%b\n" \
      "$BRIGHT_WHITE$BOLD" "$RESET" \
      "$BRIGHT_GREEN$BOLD" "$(get_name_by_ip "$dev")" "$RESET" \
      "$DIM$BRIGHT_WHITE" "$dev" "$RESET"

    adb -s "$dev" shell input keyevent KEYCODE_HOME >/dev/null 2>&1

    if [ $? -eq 0 ]; then
      ui_ok "   OK"
      ok=$((ok + 1))
    else
      ui_err "   FAIL"
      fail=$((fail + 1))
    fi

    echo ""
  done

  ui_info "Kết quả: OK=$ok | FAIL=$fail"
}

batch_open_app() {
  local pkg
  local dev

  ui_title
  ui_info "Mở app theo package trên thiết bị đã chọn"
  ui_line

  printf "%bNhập package app, ví dụ com.zing.zalo:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r pkg

  [ -z "$pkg" ] && return

  choose_devices || return

  for dev in "${SELECTED_DEVICES[@]}"; do
    printf "%b→%b %s\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$(get_name_by_ip "$dev")"

    adb -s "$dev" shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

    [ $? -eq 0 ] && ui_ok "   OK" || ui_err "   FAIL"
    echo ""
  done
}

batch_open_url() {
  local url
  local dev

  ui_title
  ui_info "Mở URL trên thiết bị đã chọn"
  ui_line

  printf "%bNhập URL:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r url

  [ -z "$url" ] && return

  choose_devices || return

  for dev in "${SELECTED_DEVICES[@]}"; do
    printf "%b→%b %s\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$(get_name_by_ip "$dev")"

    adb -s "$dev" shell am start -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1

    [ $? -eq 0 ] && ui_ok "   OK" || ui_err "   FAIL"
    echo ""
  done
}

install_apk_selected() {
  local apk
  local dev

  ui_title
  ui_info "Cài APK lên thiết bị đã chọn"
  ui_line

  printf "%bNhập đường dẫn APK:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
  read -r apk

  if [ ! -f "$apk" ]; then
    ui_err "Không thấy file APK."
    return
  fi

  choose_devices || return

  for dev in "${SELECTED_DEVICES[@]}"; do
    printf "%b→%b %s\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$(get_name_by_ip "$dev")"

    adb -s "$dev" install -r "$apk"

    [ $? -eq 0 ] && ui_ok "   INSTALL OK" || ui_err "   INSTALL FAIL"
    echo ""
  done
}

names_manager() {
  local c
  local name
  local ip
  local serial
  local n
  local devices
  local dev
  local brand
  local model
  local old_name

  while true; do
    ui_title
    ui_info "Quản lý tên máy / IP"
    ui_line
    echo "1) Xem danh sách tên máy/IP"
    echo "2) Thêm hoặc sửa tên máy"
    echo "3) Import từ thiết bị đang connect"
    echo "4) Xoá tên máy theo số thứ tự"
    echo "5) Mở file names.txt bằng nano/vi"
    echo "0) Quay lại"
    ui_line
    printf "%bChọn:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
    read -r c

    case "$c" in
      1)
        ui_title
        if [ -s "$NAME_FILE" ]; then
          nl -w2 -s") " "$NAME_FILE"
        else
          ui_warn "Chưa có tên máy nào."
        fi
        pause_enter
        ;;

      2)
        ui_title
        echo "Ví dụ:"
        echo "Tên máy: K201"
        echo "IP: 10.48.154.201"
        echo "Hệ thống sẽ tự lưu thành 10.48.154.201:$ADB_PORT"
        echo ""

        printf "%bNhập tên máy:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
        read -r name

        printf "%bNhập IP thiết bị:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
        read -r ip

        serial="$(normalize_serial "$ip")"

        if [ -z "$name" ] || [ -z "$serial" ]; then
          ui_err "Thiếu tên hoặc IP."
          pause_enter
          continue
        fi

        grep -v "|$serial$" "$NAME_FILE" > "$TMP_DIR/names_new.txt" 2>/dev/null || true
        echo "$name|$serial" >> "$TMP_DIR/names_new.txt"
        sort -u "$TMP_DIR/names_new.txt" -o "$TMP_DIR/names_new.txt"
        mv "$TMP_DIR/names_new.txt" "$NAME_FILE"

        ui_ok "Đã lưu: $name | $serial"
        pause_enter
        ;;

      3)
        ui_title
        devices="$(list_connected_devices_raw)"

        if [ -z "$devices" ]; then
          ui_err "Chưa có thiết bị đang connect."
          pause_enter
          continue
        fi

        echo "$devices" | while read -r dev; do
          old_name="$(get_name_by_ip "$dev")"

          if grep -q "|$dev$" "$NAME_FILE"; then
            ui_dim "Đã có: $old_name | $dev"
            continue
          fi

          brand="$($ADB_BIN -s "$dev" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
          model="$($ADB_BIN -s "$dev" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"

          echo ""
          ui_info "Thiết bị: $dev"
          echo "Model: $brand $model"

          printf "%bĐặt tên, bỏ trống để skip:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
          read -r name

          if [ -n "$name" ]; then
            echo "$name|$dev" >> "$NAME_FILE"
            ui_ok "Đã lưu: $name | $dev"
          fi
        done

        sort -u "$NAME_FILE" -o "$NAME_FILE"
        pause_enter
        ;;

      4)
        ui_title

        if [ ! -s "$NAME_FILE" ]; then
          ui_warn "Danh sách trống."
          pause_enter
          continue
        fi

        nl -w2 -s") " "$NAME_FILE"
        echo ""

        printf "%bNhập số thứ tự muốn xoá:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
        read -r n

        if echo "$n" | grep -Eq '^[0-9]+$'; then
          sed "${n}d" "$NAME_FILE" > "$TMP_DIR/names_del.txt"
          mv "$TMP_DIR/names_del.txt" "$NAME_FILE"
          ui_ok "Đã xoá."
        else
          ui_err "Số không hợp lệ."
        fi

        pause_enter
        ;;

      5)
        touch "$NAME_FILE"

        if has_cmd nano; then
          nano "$NAME_FILE"
        elif has_cmd vi; then
          vi "$NAME_FILE"
        else
          cat "$NAME_FILE"
          pause_enter
        fi
        ;;

      0)
        return
        ;;
    esac
  done
}

cache_manager() {
  local c
  local n
  local file
  local ok

  while true; do
    ui_title
    ui_info "Quản lý cache file/video"
    ui_line
    echo "Thư mục cache: $CACHE_DIR"
    echo ""
    echo "1) Xem file cache"
    echo "2) Push file cache sang thiết bị"
    echo "3) Xoá toàn bộ cache"
    echo "0) Quay lại"
    ui_line
    printf "%bChọn:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
    read -r c

    case "$c" in
      1)
        ui_title
        ls -lh "$CACHE_DIR"
        pause_enter
        ;;

      2)
        ui_title
        find "$CACHE_DIR" -maxdepth 1 -type f | sort > "$TMP_DIR/cache_files.txt"

        if [ ! -s "$TMP_DIR/cache_files.txt" ]; then
          ui_warn "Cache trống."
          pause_enter
          continue
        fi

        nl -w2 -s") " "$TMP_DIR/cache_files.txt"
        echo ""

        printf "%bChọn số thứ tự file:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
        read -r n

        file="$(sed -n "${n}p" "$TMP_DIR/cache_files.txt")"

        if [ ! -f "$file" ]; then
          ui_err "File không hợp lệ."
          pause_enter
          continue
        fi

        push_file_to_selected_devices "$file" "$(basename "$file")"
        pause_enter
        ;;

      3)
        printf "%bGõ YES để xoá toàn bộ cache:%b " "$BRIGHT_RED$BOLD" "$RESET"
        read -r ok

        if [ "$ok" = "YES" ]; then
          rm -f "$CACHE_DIR"/*
          clear_video_scan_cache
          ui_ok "Đã xoá cache."
        fi

        pause_enter
        ;;

      0)
        return
        ;;
    esac
  done
}

dashboard_summary() {
  ui_title
  ui_info "Dashboard trạng thái LabDroid Gateway"
  ui_line
  echo "App dir      : $APP_DIR"
  echo "Cache dir    : $CACHE_DIR"
  echo "Device file  : $DEVICE_FILE"
  echo "Names file   : $NAME_FILE"
  echo "ADB port     : $ADB_PORT cố định"
  echo ""
  echo "ADB:"
  $ADB_BIN version 2>/dev/null | head -n1 || echo "ADB chưa hoạt động"
  echo ""
  ui_ok "Tổng thiết bị connected: $(connected_count)"
  echo ""
  list_connected_devices_named
}

reboot_selected() {
  local dev
  local ok

  ui_title
  ui_err "Reboot thiết bị đã chọn"
  ui_line

  choose_devices || return

  echo ""
  printf "%bGõ YES để xác nhận reboot:%b " "$BRIGHT_RED$BOLD" "$RESET"
  read -r ok

  [ "$ok" != "YES" ] && return

  for dev in "${SELECTED_DEVICES[@]}"; do
    printf "%b→%b %s\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$(get_name_by_ip "$dev")"

    adb -s "$dev" reboot >/dev/null 2>&1

    [ $? -eq 0 ] && ui_ok "   REBOOT SENT" || ui_err "   FAIL"
    echo ""
  done
}

main_menu() {
  local choice

  while true; do
    ui_title
    printf "%b1)%b  %bScan subnet và connect thiết bị Android lab port %s%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_CYAN$BOLD" "$ADB_PORT" "$RESET"
    printf "%b2)%b  %bConnect IP thủ công port %s%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_GREEN$BOLD" "$ADB_PORT" "$RESET"
    printf "%b3)%b  %bXem thiết bị Android lab đang connect%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_YELLOW$BOLD" "$RESET"
    printf "%b4)%b  %bPush file/video lên thiết bị đã chọn%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_MAGENTA$BOLD" "$RESET"
    printf "%b5)%b  %bLiệt kê TẤT CẢ video trong lab rồi chọn mở%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_CYAN$BOLD" "$RESET"
    printf "%b6)%b  %bLiệt kê TẤT CẢ video rồi chọn đồng bộ/push%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_GREEN$BOLD" "$RESET"
    printf "%b7)%b  %bQuản lý tên máy / IP%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_YELLOW$BOLD" "$RESET"
    printf "%b8)%b  %bTải video direct URL vào cache rồi push%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_CYAN$BOLD" "$RESET"
    printf "%b9)%b  %bMở web upload video lấy direct URL%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_BLUE$BOLD" "$RESET"
    printf "%b10)%b %bĐưa thiết bị đã chọn về Home%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_CYAN$BOLD" "$RESET"
    printf "%b11)%b %bCài APK lên thiết bị đã chọn%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_YELLOW$BOLD" "$RESET"
    printf "%b12)%b %bMở app theo package trên thiết bị đã chọn%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_GREEN$BOLD" "$RESET"
    printf "%b13)%b %bMở URL trên thiết bị đã chọn%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_BLUE$BOLD" "$RESET"
    printf "%b14)%b %bQuản lý cache file/video%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_MAGENTA$BOLD" "$RESET"
    printf "%b15)%b %bDashboard trạng thái Gateway%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_CYAN$BOLD" "$RESET"
    printf "%b16)%b %bConnect lại danh sách thiết bị đã scan%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_YELLOW$BOLD" "$RESET"
    printf "%b17)%b %bScan nhanh 10.48.154 + 10.48.155 port %s%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_GREEN$BOLD" "$ADB_PORT" "$RESET"
    printf "%b18)%b %bReboot thiết bị đã chọn%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_RED$BOLD" "$RESET"
    printf "%b0)%b  %bThoát%b\n" "$BRIGHT_WHITE$BOLD" "$RESET" "$BRIGHT_RED$BOLD" "$RESET"
    ui_line
    printf "%bChọn:%b " "$BRIGHT_YELLOW$BOLD" "$RESET"
    read -r choice

    case "$choice" in
      1) scan_and_connect_subnet; pause_enter ;;
      2) connect_manual; pause_enter ;;
      3) ui_title; list_connected_devices_named; pause_enter ;;
      4) push_local_file_menu; pause_enter ;;
      5) open_lab_video_menu; pause_enter ;;
      6) sync_lab_video_menu; pause_enter ;;
      7) names_manager ;;
      8) download_url_to_cache_and_push; pause_enter ;;
      9) open_upload_web; pause_enter ;;
      10) go_home_selected; pause_enter ;;
      11) install_apk_selected; pause_enter ;;
      12) batch_open_app; pause_enter ;;
      13) batch_open_url; pause_enter ;;
      14) cache_manager ;;
      15) dashboard_summary; pause_enter ;;
      16) connect_saved_devices; pause_enter ;;
      17) quick_scan_154_155; pause_enter ;;
      18) reboot_selected; pause_enter ;;
      0)
        clear
        ui_ok "Đã thoát."
        exit 0
        ;;
      *)
        ui_err "Lựa chọn không hợp lệ."
        pause_enter
        ;;
    esac
  done
}

main() {
  mkdir -p "$APP_DIR" "$CACHE_DIR" "$TMP_DIR"
  touch "$DEVICE_FILE" "$NAME_FILE" "$LAST_FILE"

  auto_install_missing
  adb_start_clean

  main_menu
}

main