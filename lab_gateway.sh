#!/usr/bin/env bash

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
PUSH_CONCURRENCY=3

mkdir -p "$APP_DIR" "$CACHE_DIR" "$TMP_DIR"
touch "$DEVICE_FILE" "$NAME_FILE"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
MAGENTA="\033[35m"
WHITE="\033[37m"
RESET="\033[0m"
BOLD="\033[1m"

pause() {
  echo
  read -rp "Nhấn Enter để tiếp tục..."
}

line() {
  echo -e "${MAGENTA}════════════════════════════════════════════════════════════${RESET}"
}

banner() {
  clear
  echo -e "${MAGENTA}════════════════════════════════════════════════════════════${RESET}"
  echo -e "   ${GREEN}LabDroid${RESET} ${MAGENTA}Gateway${RESET} ${CYAN}- Android Lab Edge Controller${RESET}"
  echo -e "   ${YELLOW}ADB Wi-Fi fixed port:${RESET} ${GREEN}${ADB_PORT}${RESET}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${RESET}"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
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

  for c in bash adb timeout awk grep sed sort wc seq; do
    if ! has_cmd "$c"; then
      missing="$missing $c"
    fi
  done

  if [ -z "$missing" ]; then
    return
  fi

  banner
  echo -e "${YELLOW}Thiếu addon:${RESET}$missing"
  echo -e "${YELLOW}Đang thử tự cài addon cần thiết...${RESET}"
  echo

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
      echo -e "${RED}Không tự cài được vì không nhận diện được hệ thống.${RESET}"
      echo "Hãy đảm bảo môi trường có: bash, adb, timeout, awk, grep, sed, curl/wget."
      pause
      ;;
  esac
}

safe_filename() {
  echo "$1" | sed 's#[/\\:*?"<>|]#_#g'
}

normalize_serial() {
  local s="$1"
  s="$(echo "$s" | tr -d ' ')"

  if [ -z "$s" ]; then
    echo ""
    return
  fi

  ip_only="${s%%:*}"
  echo "$ip_only:$ADB_PORT"
}

check_adb_port_5555() {
  local ip="$1"
  timeout 1 bash -c "echo >/dev/tcp/$ip/$ADB_PORT" >/dev/null 2>&1
}

adb_connected_devices() {
  $ADB_BIN devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}' | grep ":$ADB_PORT$" || true
}

adb_connected_count() {
  adb_connected_devices | wc -l | tr -d ' '
}

get_name() {
  local serial="$1"
  grep "|$serial$" "$NAME_FILE" 2>/dev/null | head -n1 | cut -d'|' -f1
}

display_device() {
  local serial="$1"
  local name
  name="$(get_name "$serial")"

  if [ -n "$name" ]; then
    echo "$name | $serial"
  else
    echo "$serial"
  fi
}

save_device() {
  local serial="$1"

  if echo "$serial" | grep -q ":$ADB_PORT$"; then
    echo "$serial" >> "$DEVICE_FILE"
    sort -u "$DEVICE_FILE" -o "$DEVICE_FILE"
  fi
}

adb_connect_twice() {
  local serial="$1"
  serial="$(normalize_serial "$serial")"

  if [ -z "$serial" ]; then
    echo -e "${RED}Serial/IP trống.${RESET}"
    return 1
  fi

  $ADB_BIN connect "$serial" >/dev/null 2>&1
  sleep 1
  $ADB_BIN connect "$serial" >/dev/null 2>&1

  if $ADB_BIN devices | grep -q "^$serial[[:space:]]*device$"; then
    echo -e "${GREEN}OK   $serial${RESET}"
    save_device "$serial"
    return 0
  else
    echo -e "${RED}FAIL $serial${RESET}"
    return 1
  fi
}

print_connected_devices_for_select() {
  local devices_file="$1"
  local idx=1

  echo >&2
  echo -e "${CYAN}Danh sách thiết bị đang connect:${RESET}" >&2
  echo >&2

  while read -r serial; do
    [ -z "$serial" ] && continue
    echo "$idx) $(display_device "$serial")" >&2
    idx=$((idx + 1))
  done < "$devices_file"

  echo >&2
  echo -e "${YELLOW}Cách chọn:${RESET}" >&2
  echo "  - Chọn 1 máy      : 1" >&2
  echo "  - Chọn nhiều máy  : 1 2 5" >&2
  echo "  - Chọn tất cả     : all" >&2
  echo >&2
}

select_devices() {
  local devices_file="$TMP_DIR/select_devices.txt"
  local out_file="$TMP_DIR/selected_devices.txt"

  adb_connected_devices > "$devices_file"

  if [ ! -s "$devices_file" ]; then
    echo -e "${RED}Không có thiết bị nào đang connect port $ADB_PORT.${RESET}" >&2
    echo -e "${YELLOW}Hãy vào mục scan/connect trước rồi thử lại.${RESET}" >&2
    echo ""
    return
  fi

  print_connected_devices_for_select "$devices_file"

  read -rp "Chọn thiết bị: " choice >&2

  if [ -z "$choice" ] || echo "$choice" | grep -Eiq '^(all|a|tatca|tat ca|tất cả)$'; then
    cat "$devices_file"
    return
  fi

  > "$out_file"

  for n in $choice; do
    if echo "$n" | grep -Eq '^[0-9]+$'; then
      sed -n "${n}p" "$devices_file" >> "$out_file"
    fi
  done

  sort -u "$out_file" | grep -v '^$' || true
}

scan_subnets_5555() {
  banner
  echo -e "${CYAN}Scan Android ADB Wi-Fi port $ADB_PORT cố định${RESET}"
  line
  echo -e "${YELLOW}Ví dụ nhập:${RESET}"
  echo "10.48.154"
  echo "10.48.154 10.48.155"
  echo "192.168.1"
  echo
  read -rp "Nhập subnet cần scan: " subnets

  if [ -z "$subnets" ]; then
    echo -e "${RED}Bạn chưa nhập subnet.${RESET}"
    pause
    return
  fi

  > "$DEVICE_FILE"

  echo
  echo -e "${YELLOW}Đang scan port $ADB_PORT...${RESET}"
  echo

  for subnet in $subnets; do
    for i in $(seq 1 254); do
      ip="$subnet.$i"

      (
        if check_adb_port_5555 "$ip"; then
          serial="$ip:$ADB_PORT"
          echo "$serial" >> "$DEVICE_FILE"
          echo -e "${GREEN}OPEN $serial${RESET}"
        fi
      ) &

      while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$SCAN_CONCURRENCY" ]; do
        sleep 0.02
      done
    done
  done

  wait
  sort -u "$DEVICE_FILE" -o "$DEVICE_FILE"

  echo
  echo -e "${GREEN}Tìm thấy $(wc -l < "$DEVICE_FILE" | tr -d ' ') thiết bị mở port $ADB_PORT.${RESET}"
  pause
}

scan_and_connect_subnets_5555() {
  banner
  echo -e "${CYAN}Scan + connect Android ADB port $ADB_PORT cố định${RESET}"
  line
  echo -e "${YELLOW}Ví dụ nhập:${RESET}"
  echo "10.48.154"
  echo "10.48.154 10.48.155"
  echo "192.168.1"
  echo
  read -rp "Nhập subnet cần scan + connect: " subnets

  if [ -z "$subnets" ]; then
    echo -e "${RED}Bạn chưa nhập subnet.${RESET}"
    pause
    return
  fi

  > "$DEVICE_FILE"

  echo
  echo -e "${YELLOW}Đang scan port $ADB_PORT và adb connect 2 lần...${RESET}"
  echo

  for subnet in $subnets; do
    for i in $(seq 1 254); do
      ip="$subnet.$i"

      (
        if check_adb_port_5555 "$ip"; then
          serial="$ip:$ADB_PORT"
          echo "$serial" >> "$DEVICE_FILE"
          echo -e "${GREEN}OPEN $serial${RESET}"

          $ADB_BIN connect "$serial" >/dev/null 2>&1
          sleep 1
          $ADB_BIN connect "$serial" >/dev/null 2>&1

          if $ADB_BIN devices | grep -q "^$serial[[:space:]]*device$"; then
            echo -e "${CYAN}OK   $serial${RESET}"
          else
            echo -e "${RED}FAIL $serial${RESET}"
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

  echo
  echo -e "${CYAN}Thiết bị đã connect:${RESET}"
  adb_connected_devices | while read -r serial; do
    echo "$(display_device "$serial")"
  done
  echo
  echo -e "${GREEN}Tổng connected: $(adb_connected_count)${RESET}"
  pause
}

quick_scan_154_155() {
  banner
  echo -e "${CYAN}Scan nhanh 10.48.154.xxx + 10.48.155.xxx port $ADB_PORT${RESET}"
  line

  > "$DEVICE_FILE"

  for subnet in 154 155; do
    for i in $(seq 1 254); do
      ip="10.48.$subnet.$i"

      (
        if check_adb_port_5555 "$ip"; then
          serial="$ip:$ADB_PORT"
          echo "$serial" >> "$DEVICE_FILE"
          echo -e "${GREEN}OPEN $serial${RESET}"

          $ADB_BIN connect "$serial" >/dev/null 2>&1
          sleep 1
          $ADB_BIN connect "$serial" >/dev/null 2>&1

          if $ADB_BIN devices | grep -q "^$serial[[:space:]]*device$"; then
            echo -e "${CYAN}OK   $serial${RESET}"
          fi
        fi
      ) &
    done
  done

  wait
  sort -u "$DEVICE_FILE" -o "$DEVICE_FILE"

  echo
  echo -e "${GREEN}Tổng connected: $(adb_connected_count)${RESET}"
  pause
}

connect_manual_5555() {
  banner
  echo -e "${CYAN}Connect IP thủ công - chỉ port $ADB_PORT${RESET}"
  line
  echo "Ví dụ:"
  echo "10.48.154.116"
  echo "10.48.154.116 10.48.154.117"
  echo
  read -rp "Nhập IP thiết bị Android lab: " ips

  if [ -z "$ips" ]; then
    echo -e "${RED}Chưa nhập IP.${RESET}"
    pause
    return
  fi

  for ip in $ips; do
    serial="$(normalize_serial "$ip")"

    (
      adb_connect_twice "$serial"
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$ADB_CONCURRENCY" ]; do
      sleep 0.03
    done
  done

  wait
  pause
}

connect_saved_devices() {
  banner

  if [ ! -s "$DEVICE_FILE" ]; then
    echo -e "${RED}Chưa có danh sách thiết bị đã scan.${RESET}"
    pause
    return
  fi

  echo -e "${YELLOW}Đang connect lại danh sách đã scan port $ADB_PORT...${RESET}"
  echo

  while read -r serial; do
    serial="$(normalize_serial "$serial")"

    (
      adb_connect_twice "$serial"
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$ADB_CONCURRENCY" ]; do
      sleep 0.03
    done
  done < "$DEVICE_FILE"

  wait

  echo
  echo -e "${GREEN}Tổng connected: $(adb_connected_count)${RESET}"
  pause
}

list_adb_devices() {
  banner
  echo -e "${CYAN}Thiết bị Android lab đang connect:${RESET}"
  line

  local idx=1

  adb_connected_devices | while read -r serial; do
    model="$($ADB_BIN -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
    brand="$($ADB_BIN -s "$serial" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
    battery="$($ADB_BIN -s "$serial" shell dumpsys battery 2>/dev/null | awk -F': ' '/level/ {print $2; exit}' | tr -d '\r')"
    echo "$idx) $(display_device "$serial") | ${brand:-?} ${model:-?} | Pin: ${battery:-?}%"
    idx=$((idx + 1))
  done

  echo
  echo -e "${GREEN}Tổng connected: $(adb_connected_count)${RESET}"
  pause
}

batch_push_file() {
  banner
  echo -e "${CYAN}Đẩy file/video lên thiết bị Android lab${RESET}"
  line

  if [ -f "$LAST_FILE" ]; then
    last_path="$(cat "$LAST_FILE")"
    echo -e "${YELLOW}File lần trước:${RESET} $last_path"
    read -rp "Enter để dùng lại, hoặc nhập file mới: " file
    [ -z "$file" ] && file="$last_path"
  else
    read -rp "Nhập đường dẫn file/video trên máy gateway: " file
  fi

  if [ ! -f "$file" ]; then
    echo -e "${RED}Không thấy file:${RESET} $file"
    pause
    return
  fi

  echo "$file" > "$LAST_FILE"

  targets="$(select_devices)"

  if [ -z "$targets" ]; then
    echo -e "${RED}Không có thiết bị nào được chọn.${RESET}"
    pause
    return
  fi

  filename="$(basename "$file")"
  remote="/sdcard/Download/$filename"

  echo
  echo -e "${YELLOW}File nguồn:${RESET} $file"
  echo -e "${YELLOW}Đường dẫn đích:${RESET} $remote"
  echo

  echo "$targets" | while read -r serial; do
    [ -z "$serial" ] && continue

    (
      echo -e "${YELLOW}PUSH → $(display_device "$serial")${RESET}"
      $ADB_BIN -s "$serial" push "$file" "$remote"

      if [ $? -eq 0 ]; then
        echo -e "${GREEN}PUSH OK → $(display_device "$serial")${RESET}"
      else
        echo -e "${RED}PUSH FAIL → $(display_device "$serial")${RESET}"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PUSH_CONCURRENCY" ]; do
      sleep 0.2
    done
  done

  wait
  pause
}

get_remote_videos() {
  local serial="$1"

  $ADB_BIN -s "$serial" shell 'ls -1 /sdcard/Download 2>/dev/null' | \
    tr -d '\r' | \
    grep -Ei '\.(mp4|mkv|avi|mov|m4v|3gp|webm)$' | \
    sort -u
}

build_all_video_list() {
  local vote_file="$TMP_DIR/video_votes.txt"
  local map_file="$TMP_DIR/video_map.txt"
  local list_file="$TMP_DIR/all_videos_list.txt"
  local count_file="$TMP_DIR/all_video_count.txt"
  local device_file="$TMP_DIR/video_devices.txt"

  > "$vote_file"
  > "$map_file"
  > "$list_file"
  > "$count_file"
  > "$device_file"

  adb_connected_devices > "$device_file"

  if [ ! -s "$device_file" ]; then
    echo -e "${RED}Chưa có thiết bị ADB connected port $ADB_PORT.${RESET}" >&2
    echo -e "${YELLOW}Hãy scan/connect trước rồi thử lại.${RESET}" >&2
    return 1
  fi

  local count
  count="$(wc -l < "$device_file" | tr -d ' ')"

  echo >&2
  echo -e "${YELLOW}Đang quét toàn bộ video trong /sdcard/Download trên $count thiết bị...${RESET}" >&2
  echo >&2

  while read -r serial; do
    (
      tmp_each="$TMP_DIR/videos_${serial//[:.]/_}.txt"

      get_remote_videos "$serial" > "$tmp_each"

      if [ -s "$tmp_each" ]; then
        while read -r v; do
          [ -z "$v" ] && continue
          echo "$v" >> "$vote_file"
          echo "$v|$serial" >> "$map_file"
        done < "$tmp_each"

        echo -e "${GREEN}DONE → $(display_device "$serial") | $(wc -l < "$tmp_each" | tr -d ' ') video${RESET}" >&2
      else
        echo -e "${YELLOW}EMPTY → $(display_device "$serial") | không thấy video${RESET}" >&2
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$VIDEO_SCAN_CONCURRENCY" ]; do
      sleep 0.05
    done
  done < "$device_file"

  wait

  if [ ! -s "$vote_file" ]; then
    echo >&2
    echo -e "${RED}Không tìm thấy video nào trong /sdcard/Download.${RESET}" >&2
    return 1
  fi

  sort "$vote_file" | uniq -c | sort -nr > "$count_file"
  awk '{$1=""; sub(/^ /,""); print}' "$count_file" > "$list_file"

  echo >&2
  echo -e "${CYAN}Danh sách video tìm thấy:${RESET}" >&2
  echo >&2

  local idx=1

  while read -r video; do
    [ -z "$video" ] && continue
    have_count="$(grep -Fx "$video" "$vote_file" | wc -l | tr -d ' ')"
    echo "$idx) [$have_count/$count máy có] $video" >&2
    idx=$((idx + 1))
  done < "$list_file"

  return 0
}

choose_video_from_lab() {
  build_all_video_list || return 1

  echo >&2
  echo -e "${YELLOW}Cách chọn:${RESET} nhập số thứ tự video, ví dụ 1 hoặc 2" >&2
  read -rp "Chọn video số: " n >&2

  if ! echo "$n" | grep -Eq '^[0-9]+$'; then
    echo -e "${RED}Lựa chọn không hợp lệ.${RESET}" >&2
    return 1
  fi

  local video
  video="$(sed -n "${n}p" "$TMP_DIR/all_videos_list.txt")"

  if [ -z "$video" ]; then
    echo -e "${RED}Không có video ở số thứ tự này.${RESET}" >&2
    return 1
  fi

  printf "%s\n" "$video"
}

find_source_device_from_map() {
  local video="$1"
  local map_file="$TMP_DIR/video_map.txt"

  awk -F'|' -v v="$video" '$1 == v {print $2; exit}' "$map_file"
}

feature_open_lab_video() {
  banner
  echo -e "${CYAN}Liệt kê video trong lab rồi chọn mở${RESET}"
  line

  video="$(choose_video_from_lab)" || {
    pause
    return
  }

  echo
  echo -e "${GREEN}Video đã chọn:${RESET} $video"

  targets="$(select_devices)"

  if [ -z "$targets" ]; then
    echo -e "${RED}Không có thiết bị nào được chọn.${RESET}"
    pause
    return
  fi

  echo
  echo -e "${YELLOW}Đang mở video trên thiết bị đã chọn...${RESET}"
  echo

  echo "$targets" | while read -r serial; do
    [ -z "$serial" ] && continue

    (
      $ADB_BIN -s "$serial" shell am start \
        -a android.intent.action.VIEW \
        -d "file:///sdcard/Download/$video" \
        -t "video/*" >/dev/null 2>&1

      echo -e "${GREEN}MỞ VIDEO → $(display_device "$serial")${RESET}"
    ) &
  done

  wait
  pause
}

feature_sync_lab_video() {
  banner
  echo -e "${CYAN}Liệt kê video trong lab rồi đồng bộ/push sang thiết bị đã chọn${RESET}"
  line

  video="$(choose_video_from_lab)" || {
    pause
    return
  }

  echo
  echo -e "${GREEN}Video đã chọn:${RESET} $video"

  source_serial="$(find_source_device_from_map "$video")"

  if [ -z "$source_serial" ]; then
    echo -e "${RED}Không tìm được máy nguồn trong dữ liệu đã quét.${RESET}"
    pause
    return
  fi

  echo -e "${CYAN}Máy nguồn:${RESET} $(display_device "$source_serial")"

  local_name="$(safe_filename "$video")"
  local_file="$CACHE_DIR/$local_name"

  if [ -f "$local_file" ]; then
    echo -e "${GREEN}Cache đã có:${RESET} $local_file"
  else
    echo
    echo -e "${YELLOW}Đang pull video từ máy nguồn về cache...${RESET}"
    echo -e "${YELLOW}Nguồn:${RESET} $source_serial:/sdcard/Download/$video"
    echo -e "${YELLOW}Cache:${RESET} $local_file"
    echo

    $ADB_BIN -s "$source_serial" pull "/sdcard/Download/$video" "$local_file"

    if [ $? -ne 0 ] || [ ! -f "$local_file" ]; then
      echo -e "${RED}Pull thất bại.${RESET}"
      echo -e "${YELLOW}Thử kiểm tra thủ công:${RESET}"
      echo "adb -s $source_serial shell ls -l /sdcard/Download"
      pause
      return
    fi
  fi

  echo
  echo -e "${CYAN}Bây giờ chọn thiết bị đích để push video sang.${RESET}"

  targets="$(select_devices)"

  if [ -z "$targets" ]; then
    echo -e "${RED}Không có thiết bị nào được chọn.${RESET}"
    pause
    return
  fi

  echo
  read -rp "Bỏ qua máy đã có video này? [Y/n]: " skip_have
  [ -z "$skip_have" ] && skip_have="Y"

  read -rp "Push xong có phát luôn không? [y/N]: " play_now

  echo
  echo -e "${YELLOW}Đang push video sang thiết bị đã chọn...${RESET}"
  echo

  echo "$targets" | while read -r serial; do
    [ -z "$serial" ] && continue

    (
      if echo "$skip_have" | grep -qi '^y'; then
        if $ADB_BIN -s "$serial" shell "ls '/sdcard/Download/$video'" >/dev/null 2>&1; then
          echo -e "${CYAN}SKIP đã có → $(display_device "$serial")${RESET}"
          exit 0
        fi
      fi

      echo -e "${YELLOW}PUSH → $(display_device "$serial")${RESET}"
      $ADB_BIN -s "$serial" push "$local_file" "/sdcard/Download/$video"

      if [ $? -eq 0 ]; then
        echo -e "${GREEN}PUSH OK → $(display_device "$serial")${RESET}"

        if echo "$play_now" | grep -qi '^y'; then
          $ADB_BIN -s "$serial" shell am start \
            -a android.intent.action.VIEW \
            -d "file:///sdcard/Download/$video" \
            -t "video/*" >/dev/null 2>&1

          echo -e "${GREEN}PHÁT → $(display_device "$serial")${RESET}"
        fi
      else
        echo -e "${RED}PUSH FAIL → $(display_device "$serial")${RESET}"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PUSH_CONCURRENCY" ]; do
      sleep 0.2
    done
  done

  wait
  pause
}

names_manager() {
  while true; do
    banner
    echo -e "${CYAN}Quản lý tên máy / IP${RESET}"
    line
    echo "1) Xem danh sách tên máy/IP"
    echo "2) Thêm hoặc sửa tên máy"
    echo "3) Import từ thiết bị đang connect"
    echo "4) Xoá tên máy theo số thứ tự"
    echo "5) Mở file names.txt bằng nano/vi"
    echo "0) Quay lại"
    line
    read -rp "Chọn: " c

    case "$c" in
      1)
        banner
        if [ -s "$NAME_FILE" ]; then
          nl -w2 -s") " "$NAME_FILE"
        else
          echo -e "${RED}Chưa có tên máy nào.${RESET}"
        fi
        pause
        ;;

      2)
        banner
        echo -e "${YELLOW}Ví dụ:${RESET}"
        echo "Tên máy: K201"
        echo "IP: 10.48.154.201"
        echo "Hệ thống sẽ tự lưu thành 10.48.154.201:$ADB_PORT"
        echo

        read -rp "Nhập tên máy: " name
        read -rp "Nhập IP thiết bị: " ip

        serial="$(normalize_serial "$ip")"

        if [ -z "$name" ] || [ -z "$serial" ]; then
          echo -e "${RED}Thiếu tên hoặc IP.${RESET}"
          pause
          continue
        fi

        grep -v "|$serial$" "$NAME_FILE" > "$TMP_DIR/names_new.txt" 2>/dev/null || true
        echo "$name|$serial" >> "$TMP_DIR/names_new.txt"
        sort -u "$TMP_DIR/names_new.txt" -o "$TMP_DIR/names_new.txt"
        mv "$TMP_DIR/names_new.txt" "$NAME_FILE"

        echo -e "${GREEN}Đã lưu: $name | $serial${RESET}"
        pause
        ;;

      3)
        banner
        devices="$(adb_connected_devices)"

        if [ -z "$devices" ]; then
          echo -e "${RED}Chưa có thiết bị đang connect.${RESET}"
          pause
          continue
        fi

        echo "$devices" | while read -r serial; do
          old_name="$(get_name "$serial")"

          if [ -n "$old_name" ]; then
            echo -e "${CYAN}Đã có:${RESET} $old_name | $serial"
            continue
          fi

          brand="$($ADB_BIN -s "$serial" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
          model="$($ADB_BIN -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"

          echo
          echo -e "${YELLOW}Thiết bị:${RESET} $serial"
          echo "Model: $brand $model"
          read -rp "Đặt tên, bỏ trống để skip: " name

          if [ -n "$name" ]; then
            echo "$name|$serial" >> "$NAME_FILE"
            echo -e "${GREEN}Đã lưu: $name | $serial${RESET}"
          fi
        done

        sort -u "$NAME_FILE" -o "$NAME_FILE"
        pause
        ;;

      4)
        banner

        if [ ! -s "$NAME_FILE" ]; then
          echo -e "${RED}Danh sách trống.${RESET}"
          pause
          continue
        fi

        nl -w2 -s") " "$NAME_FILE"
        echo
        read -rp "Nhập số thứ tự muốn xoá: " n

        if echo "$n" | grep -Eq '^[0-9]+$'; then
          sed "${n}d" "$NAME_FILE" > "$TMP_DIR/names_del.txt"
          mv "$TMP_DIR/names_del.txt" "$NAME_FILE"
          echo -e "${GREEN}Đã xoá.${RESET}"
        else
          echo -e "${RED}Số không hợp lệ.${RESET}"
        fi

        pause
        ;;

      5)
        touch "$NAME_FILE"

        if has_cmd nano; then
          nano "$NAME_FILE"
        elif has_cmd vi; then
          vi "$NAME_FILE"
        else
          echo "File: $NAME_FILE"
          cat "$NAME_FILE"
          pause
        fi
        ;;

      0)
        return
        ;;
    esac
  done
}

download_url_to_cache() {
  banner
  echo -e "${CYAN}Tải video từ URL direct vào cache rồi đẩy sang thiết bị${RESET}"
  line

  read -rp "Nhập URL direct: " url

  if [ -z "$url" ]; then
    echo -e "${RED}Chưa nhập URL.${RESET}"
    pause
    return
  fi

  default_name="$(basename "${url%%\?*}" | sed 's/%20/ /g')"

  if [ -z "$default_name" ] || ! echo "$default_name" | grep -q '\.'; then
    default_name="video_$(date +%Y%m%d_%H%M%S).mp4"
  fi

  echo
  echo -e "${YELLOW}Tên gợi ý:${RESET} $default_name"
  read -rp "Nhập tên mới, Enter để giữ nguyên: " new_name

  [ -z "$new_name" ] && new_name="$default_name"
  new_name="$(safe_filename "$new_name")"

  local_file="$CACHE_DIR/$new_name"

  echo
  echo -e "${YELLOW}Đang tải về:${RESET} $local_file"

  if has_cmd curl; then
    curl -L --progress-bar "$url" -o "$local_file"
  elif has_cmd wget; then
    wget -O "$local_file" "$url"
  else
    echo -e "${RED}Thiếu curl/wget.${RESET}"
    pause
    return
  fi

  if [ $? -ne 0 ] || [ ! -f "$local_file" ]; then
    echo -e "${RED}Tải thất bại.${RESET}"
    pause
    return
  fi

  echo "$local_file" > "$LAST_FILE"

  echo
  echo -e "${GREEN}Tải xong:${RESET} $local_file"
  ls -lh "$local_file" 2>/dev/null
  echo

  read -rp "Có đẩy sang thiết bị luôn không? [Y/n]: " do_push
  [ -z "$do_push" ] && do_push="Y"

  if ! echo "$do_push" | grep -qi '^y'; then
    pause
    return
  fi

  targets="$(select_devices)"

  if [ -z "$targets" ]; then
    echo -e "${RED}Không có thiết bị nào được chọn.${RESET}"
    pause
    return
  fi

  read -rp "Đẩy xong có mở video luôn không? [y/N]: " play_now

  remote="/sdcard/Download/$new_name"

  echo "$targets" | while read -r serial; do
    [ -z "$serial" ] && continue

    (
      echo -e "${YELLOW}PUSH → $(display_device "$serial")${RESET}"
      $ADB_BIN -s "$serial" push "$local_file" "$remote"

      if [ $? -eq 0 ]; then
        echo -e "${GREEN}PUSH OK → $(display_device "$serial")${RESET}"

        if echo "$play_now" | grep -qi '^y'; then
          $ADB_BIN -s "$serial" shell am start \
            -a android.intent.action.VIEW \
            -d "file://$remote" \
            -t "video/*" >/dev/null 2>&1

          echo -e "${GREEN}PHÁT → $(display_device "$serial")${RESET}"
        fi
      else
        echo -e "${RED}PUSH FAIL → $(display_device "$serial")${RESET}"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PUSH_CONCURRENCY" ]; do
      sleep 0.2
    done
  done

  wait
  pause
}

open_upload_web() {
  banner
  echo -e "${CYAN}Mở web upload video lấy URL direct${RESET}"
  line
  echo "$UPLOAD_WEB_URL"
  echo

  if has_cmd termux-open-url; then
    termux-open-url "$UPLOAD_WEB_URL"
    echo -e "${GREEN}Đã mở web upload.${RESET}"
  elif has_cmd xdg-open; then
    xdg-open "$UPLOAD_WEB_URL" >/dev/null 2>&1
    echo -e "${GREEN}Đã mở web upload.${RESET}"
  elif has_cmd am; then
    am start -a android.intent.action.VIEW -d "$UPLOAD_WEB_URL" >/dev/null 2>&1
    echo -e "${GREEN}Đã mở web upload.${RESET}"
  else
    echo -e "${YELLOW}Không tự mở được. Copy link trên vào trình duyệt.${RESET}"
  fi

  pause
}

batch_home() {
  banner
  echo -e "${CYAN}Đưa thiết bị đã chọn về màn hình Home${RESET}"
  line

  targets="$(select_devices)"
  if [ -z "$targets" ]; then
    echo -e "${RED}Không có thiết bị nào được chọn.${RESET}"
    pause
    return
  fi

  echo "$targets" | while read -r serial; do
    [ -z "$serial" ] && continue

    (
      $ADB_BIN -s "$serial" shell input keyevent KEYCODE_HOME >/dev/null 2>&1
      echo -e "${GREEN}HOME → $(display_device "$serial")${RESET}"
    ) &
  done

  wait
  pause
}

batch_open_app() {
  banner
  echo -e "${CYAN}Mở app hàng loạt theo package name${RESET}"
  line
  read -rp "Nhập package app, ví dụ com.zing.zalo: " pkg

  [ -z "$pkg" ] && return

  targets="$(select_devices)"

  if [ -z "$targets" ]; then
    echo -e "${RED}Không có thiết bị nào được chọn.${RESET}"
    pause
    return
  fi

  echo "$targets" | while read -r serial; do
    [ -z "$serial" ] && continue

    (
      $ADB_BIN -s "$serial" shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
      echo -e "${GREEN}MỞ APP → $(display_device "$serial")${RESET}"
    ) &
  done

  wait
  pause
}

batch_open_url() {
  banner
  echo -e "${CYAN}Mở URL hàng loạt${RESET}"
  line
  read -rp "Nhập URL: " url

  [ -z "$url" ] && return

  targets="$(select_devices)"

  if [ -z "$targets" ]; then
    echo -e "${RED}Không có thiết bị nào được chọn.${RESET}"
    pause
    return
  fi

  echo "$targets" | while read -r serial; do
    [ -z "$serial" ] && continue

    (
      $ADB_BIN -s "$serial" shell am start -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1
      echo -e "${GREEN}MỞ URL → $(display_device "$serial")${RESET}"
    ) &
  done

  wait
  pause
}

batch_install_apk() {
  banner
  echo -e "${CYAN}Cài APK hàng loạt${RESET}"
  line
  read -rp "Nhập đường dẫn APK: " apk

  if [ ! -f "$apk" ]; then
    echo -e "${RED}Không thấy file APK.${RESET}"
    pause
    return
  fi

  targets="$(select_devices)"

  if [ -z "$targets" ]; then
    echo -e "${RED}Không có thiết bị nào được chọn.${RESET}"
    pause
    return
  fi

  echo "$targets" | while read -r serial; do
    [ -z "$serial" ] && continue

    (
      echo -e "${YELLOW}INSTALL → $(display_device "$serial")${RESET}"
      $ADB_BIN -s "$serial" install -r "$apk" >/dev/null 2>&1

      if [ $? -eq 0 ]; then
        echo -e "${GREEN}INSTALL OK → $(display_device "$serial")${RESET}"
      else
        echo -e "${RED}INSTALL FAIL → $(display_device "$serial")${RESET}"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge 4 ]; do
      sleep 0.2
    done
  done

  wait
  pause
}

cache_manager() {
  while true; do
    banner
    echo -e "${CYAN}Quản lý cache file/video${RESET}"
    line
    echo "Thư mục cache: $CACHE_DIR"
    echo
    echo "1) Xem file cache"
    echo "2) Đẩy file cache sang thiết bị"
    echo "3) Xoá toàn bộ cache"
    echo "0) Quay lại"
    line
    read -rp "Chọn: " c

    case "$c" in
      1)
        banner
        ls -lh "$CACHE_DIR"
        pause
        ;;

      2)
        banner
        find "$CACHE_DIR" -maxdepth 1 -type f | sort > "$TMP_DIR/cache_files.txt"

        if [ ! -s "$TMP_DIR/cache_files.txt" ]; then
          echo -e "${RED}Cache trống.${RESET}"
          pause
          continue
        fi

        nl -w2 -s") " "$TMP_DIR/cache_files.txt"
        echo
        read -rp "Chọn số thứ tự file: " n
        file="$(sed -n "${n}p" "$TMP_DIR/cache_files.txt")"

        if [ ! -f "$file" ]; then
          echo -e "${RED}File không hợp lệ.${RESET}"
          pause
          continue
        fi

        echo "$file" > "$LAST_FILE"

        targets="$(select_devices)"

        if [ -z "$targets" ]; then
          echo -e "${RED}Không có thiết bị nào được chọn.${RESET}"
          pause
          continue
        fi

        read -rp "Đẩy xong có mở video luôn không? [y/N]: " play_now

        name="$(basename "$file")"
        remote="/sdcard/Download/$name"

        echo "$targets" | while read -r serial; do
          [ -z "$serial" ] && continue

          (
            echo -e "${YELLOW}PUSH → $(display_device "$serial")${RESET}"
            $ADB_BIN -s "$serial" push "$file" "$remote"

            if [ $? -eq 0 ]; then
              echo -e "${GREEN}PUSH OK → $(display_device "$serial")${RESET}"

              if echo "$play_now" | grep -qi '^y'; then
                $ADB_BIN -s "$serial" shell am start \
                  -a android.intent.action.VIEW \
                  -d "file://$remote" \
                  -t "video/*" >/dev/null 2>&1
                echo -e "${GREEN}PHÁT → $(display_device "$serial")${RESET}"
              fi
            else
              echo -e "${RED}PUSH FAIL → $(display_device "$serial")${RESET}"
            fi
          ) &

          while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$PUSH_CONCURRENCY" ]; do
            sleep 0.2
          done
        done

        wait
        pause
        ;;

      3)
        read -rp "Gõ YES để xoá toàn bộ cache: " ok
        if [ "$ok" = "YES" ]; then
          rm -f "$CACHE_DIR"/*
          echo -e "${GREEN}Đã xoá cache.${RESET}"
        fi
        pause
        ;;

      0)
        return
        ;;
    esac
  done
}

dashboard_summary() {
  banner
  echo -e "${CYAN}Dashboard trạng thái LabDroid Gateway${RESET}"
  line
  echo "App dir      : $APP_DIR"
  echo "Cache dir    : $CACHE_DIR"
  echo "Device file  : $DEVICE_FILE"
  echo "Names file   : $NAME_FILE"
  echo "ADB port     : $ADB_PORT cố định"
  echo
  echo "ADB:"
  $ADB_BIN version 2>/dev/null | head -n1 || echo "ADB chưa hoạt động"
  echo
  echo -e "${GREEN}Tổng thiết bị connected: $(adb_connected_count)${RESET}"
  echo

  idx=1

  adb_connected_devices | while read -r serial; do
    brand="$($ADB_BIN -s "$serial" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
    model="$($ADB_BIN -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
    battery="$($ADB_BIN -s "$serial" shell dumpsys battery 2>/dev/null | awk -F': ' '/level/ {print $2; exit}' | tr -d '\r')"
    echo "$idx) $(display_device "$serial") | ${brand:-?} ${model:-?} | Pin: ${battery:-?}%"
    idx=$((idx + 1))
  done

  pause
}

batch_reboot() {
  banner
  echo -e "${RED}Reboot thiết bị đã chọn${RESET}"
  line

  targets="$(select_devices)"

  if [ -z "$targets" ]; then
    echo -e "${RED}Không có thiết bị nào được chọn.${RESET}"
    pause
    return
  fi

  echo
  read -rp "Gõ YES để xác nhận reboot: " ok

  [ "$ok" != "YES" ] && return

  echo "$targets" | while read -r serial; do
    [ -z "$serial" ] && continue

    (
      $ADB_BIN -s "$serial" reboot >/dev/null 2>&1
      echo -e "${YELLOW}REBOOT → $(display_device "$serial")${RESET}"
    ) &
  done

  wait
  pause
}

main_menu() {
  auto_install_missing

  while true; do
    banner
    echo -e "1)  🔎 ${CYAN}Scan subnet và connect thiết bị Android lab port ${ADB_PORT}${RESET}"
    echo -e "2)  🔗 ${GREEN}Connect IP thủ công port ${ADB_PORT}${RESET}"
    echo -e "3)  📋 ${YELLOW}Xem thiết bị Android lab đang connect${RESET}"
    echo -e "4)  📤 ${MAGENTA}Đẩy file/video lên thiết bị đã chọn${RESET}"
    echo -e "5)  🎬 ${CYAN}Liệt kê video trong lab rồi chọn mở${RESET}"
    echo -e "6)  🔄 ${GREEN}Liệt kê video trong lab rồi chọn đồng bộ/push${RESET}"
    echo -e "7)  🗂️  ${YELLOW}Quản lý tên máy / IP${RESET}"
    echo -e "8)  🌐 ${CYAN}Tải video direct URL vào cache rồi đẩy sang thiết bị${RESET}"
    echo -e "9)  🌍 ${BLUE}Mở web upload video lấy direct URL${RESET}"
    echo -e "10) 🏠 ${CYAN}Đưa thiết bị đã chọn về Home${RESET}"
    echo -e "11) 📦 ${YELLOW}Cài APK lên thiết bị đã chọn${RESET}"
    echo -e "12) 🚀 ${GREEN}Mở app theo package trên thiết bị đã chọn${RESET}"
    echo -e "13) 🔗 ${BLUE}Mở URL trên thiết bị đã chọn${RESET}"
    echo -e "14) 🧹 ${MAGENTA}Quản lý cache file/video${RESET}"
    echo -e "15) 📊 ${CYAN}Dashboard trạng thái Gateway${RESET}"
    echo -e "16) ♻️  ${YELLOW}Connect lại danh sách thiết bị đã scan${RESET}"
    echo -e "17) ⚡ ${GREEN}Scan nhanh 10.48.154 + 10.48.155 port ${ADB_PORT}${RESET}"
    echo -e "18) 🔁 ${RED}Reboot thiết bị đã chọn${RESET}"
    echo -e "0)  ✖ ${RED}Thoát${RESET}"
    line
    read -rp "Chọn: " c

    case "$c" in
      1) scan_and_connect_subnets_5555 ;;
      2) connect_manual_5555 ;;
      3) list_adb_devices ;;
      4) batch_push_file ;;
      5) feature_open_lab_video ;;
      6) feature_sync_lab_video ;;
      7) names_manager ;;
      8) download_url_to_cache ;;
      9) open_upload_web ;;
      10) batch_home ;;
      11) batch_install_apk ;;
      12) batch_open_app ;;
      13) batch_open_url ;;
      14) cache_manager ;;
      15) dashboard_summary ;;
      16) connect_saved_devices ;;
      17) quick_scan_154_155 ;;
      18) batch_reboot ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

main_menu