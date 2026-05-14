#!/usr/bin/env bash

PORT=5555
ADB_BIN="${ADB_BIN:-adb}"
APP_DIR="$HOME/.labdroid"
DEVICE_FILE="$APP_DIR/devices.txt"
NAME_FILE="$APP_DIR/names.txt"
LAST_FILE="$APP_DIR/last_file.txt"
COMMON_THRESHOLD_PERCENT=60

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"
BOLD="\033[1m"

mkdir -p "$APP_DIR"

pause() {
  echo
  read -rp "Nhấn Enter để tiếp tục..."
}

line() {
  echo "────────────────────────────────────────"
}

banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║              LabDroid Gateway                ║"
  echo "║        Android Tablet Edge Controller        ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"
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
  banner

  echo -e "${YELLOW}Đang kiểm tra addon cần thiết...${RESET}"
  echo

  MISSING=""

  for c in bash adb timeout awk grep sed sort wc seq; do
    if has_cmd "$c"; then
      echo -e "${GREEN}OK${RESET} $c"
    else
      echo -e "${RED}MISS${RESET} $c"
      MISSING="$MISSING $c"
    fi
  done

  if [ -z "$MISSING" ]; then
    echo
    echo -e "${GREEN}Tất cả addon cần thiết đã có.${RESET}"
    sleep 1
    return
  fi

  ENV_TYPE="$(detect_env)"
  echo
  echo -e "${YELLOW}Môi trường: $ENV_TYPE${RESET}"
  echo -e "${YELLOW}Đang tự cài phần thiếu nếu hệ thống hỗ trợ...${RESET}"
  echo

  case "$ENV_TYPE" in
    termux)
      pkg update -y
      pkg install -y bash android-tools coreutils grep gawk sed curl wget iproute2
      ;;
    alpine)
      apk update || true
      apk add bash android-tools coreutils grep gawk sed curl wget iproute2
      ;;
    debian)
      sudo apt update -y || apt update -y || true
      sudo apt install -y bash android-tools-adb coreutils grep gawk sed curl wget iproute2 || \
      apt install -y bash android-tools-adb coreutils grep gawk sed curl wget iproute2
      ;;
    *)
      echo -e "${RED}Không thể tự cài vì không nhận diện được package manager.${RESET}"
      echo "Nếu là ADBify, hãy đảm bảo môi trường đã có adb, bash, timeout."
      pause
      ;;
  esac
}

check_port_5555() {
  local ip="$1"
  timeout 1 bash -c "echo >/dev/tcp/$ip/$PORT" >/dev/null 2>&1
}

adb_connected_count() {
  $ADB_BIN devices 2>/dev/null | grep -c '5555.*device$'
}

adb_connect_twice() {
  local target="$1"

  $ADB_BIN connect "$target" >/dev/null 2>&1
  sleep 1
  $ADB_BIN connect "$target" >/dev/null 2>&1

  if $ADB_BIN devices | grep -q "^$target[[:space:]]*device$"; then
    echo -e "${GREEN}OK   $target${RESET}"
  else
    echo -e "${RED}FAIL $target${RESET}"
  fi
}

get_name() {
  local target="$1"

  if [ -f "$NAME_FILE" ]; then
    grep "|$target$" "$NAME_FILE" | head -n1 | cut -d'|' -f1
  fi
}

show_target() {
  local target="$1"
  local name
  name="$(get_name "$target")"

  if [ -n "$name" ]; then
    echo "$name | $target"
  else
    echo "$target"
  fi
}

save_device() {
  local target="$1"
  echo "$target" >> "$DEVICE_FILE"
}

dedupe_devices() {
  [ -f "$DEVICE_FILE" ] && sort -u "$DEVICE_FILE" -o "$DEVICE_FILE"
}

scan_custom_subnets() {
  banner

  echo -e "${YELLOW}Ví dụ nhập:${RESET}"
  echo "10.48.154"
  echo "10.48.154 10.48.155"
  echo "192.168.1"
  echo

  read -rp "Nhập subnet cần scan: " SUBNETS

  if [ -z "$SUBNETS" ]; then
    echo -e "${RED}Bạn chưa nhập subnet.${RESET}"
    pause
    return
  fi

  > "$DEVICE_FILE"

  echo
  echo -e "${YELLOW}Đang scan port $PORT...${RESET}"
  echo

  for subnet in $SUBNETS; do
    for i in $(seq 1 254); do
      ip="$subnet.$i"

      (
        if check_port_5555 "$ip"; then
          target="$ip:$PORT"
          save_device "$target"
          echo -e "${GREEN}OPEN $target${RESET}"
        fi
      ) &

      while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge 64 ]; do
        sleep 0.02
      done
    done
  done

  wait
  dedupe_devices

  echo
  echo -e "${CYAN}Tìm thấy $(wc -l < "$DEVICE_FILE" | tr -d ' ') thiết bị mở port $PORT.${RESET}"
  pause
}

scan_and_connect_custom_subnets() {
  banner

  echo -e "${YELLOW}Ví dụ nhập:${RESET}"
  echo "10.48.154"
  echo "10.48.154 10.48.155"
  echo "192.168.1"
  echo

  read -rp "Nhập subnet cần scan + connect: " SUBNETS

  if [ -z "$SUBNETS" ]; then
    echo -e "${RED}Bạn chưa nhập subnet.${RESET}"
    pause
    return
  fi

  > "$DEVICE_FILE"

  echo
  echo -e "${YELLOW}Đang scan và adb connect...${RESET}"
  echo

  for subnet in $SUBNETS; do
    for i in $(seq 1 254); do
      ip="$subnet.$i"

      (
        if check_port_5555 "$ip"; then
          target="$ip:$PORT"
          save_device "$target"
          echo -e "${GREEN}OPEN $target${RESET}"

          $ADB_BIN connect "$target" >/dev/null 2>&1
          sleep 1
          $ADB_BIN connect "$target" >/dev/null 2>&1

          if $ADB_BIN devices | grep -q "^$target[[:space:]]*device$"; then
            echo -e "${CYAN}OK   $target${RESET}"
          else
            echo -e "${RED}FAIL $target${RESET}"
          fi
        fi
      ) &

      while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge 64 ]; do
        sleep 0.02
      done
    done
  done

  wait
  dedupe_devices

  echo
  echo -e "${CYAN}ADB devices:${RESET}"
  $ADB_BIN devices | grep ":5555" || true
  echo
  echo -e "${GREEN}Tổng connected: $(adb_connected_count)${RESET}"

  pause
}

quick_scan_154_155() {
  banner

  > "$DEVICE_FILE"

  echo -e "${YELLOW}Đang scan nhanh 10.48.154.xxx và 10.48.155.xxx...${RESET}"
  echo

  for subnet in 154 155; do
    for i in $(seq 1 254); do
      ip="10.48.$subnet.$i"

      (
        if check_port_5555 "$ip"; then
          target="$ip:$PORT"
          save_device "$target"
          echo -e "${GREEN}OPEN $ip${RESET}"

          $ADB_BIN connect "$target" >/dev/null 2>&1
          sleep 1
          $ADB_BIN connect "$target" >/dev/null 2>&1

          if $ADB_BIN devices | grep -q "^$target[[:space:]]*device$"; then
            echo -e "${CYAN}OK $target${RESET}"
          fi
        fi
      ) &
    done
  done

  wait
  dedupe_devices

  echo
  $ADB_BIN devices | grep ":5555" || true
  echo
  echo -e "${GREEN}Tổng: $(adb_connected_count)${RESET}"

  pause
}

connect_saved_devices() {
  banner

  if [ ! -s "$DEVICE_FILE" ]; then
    echo -e "${RED}Chưa có danh sách thiết bị. Hãy scan trước.${RESET}"
    pause
    return
  fi

  echo -e "${YELLOW}Đang connect lại danh sách đã scan...${RESET}"
  echo

  while read -r target; do
    (
      adb_connect_twice "$target"
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge 32 ]; do
      sleep 0.02
    done
  done < "$DEVICE_FILE"

  wait

  echo
  echo -e "${CYAN}ADB devices:${RESET}"
  $ADB_BIN devices | grep ":5555" || true
  echo
  echo -e "${GREEN}Tổng connected: $(adb_connected_count)${RESET}"

  pause
}

list_saved_devices() {
  banner

  if [ ! -s "$DEVICE_FILE" ]; then
    echo -e "${RED}Chưa có danh sách thiết bị đã scan.${RESET}"
    pause
    return
  fi

  echo -e "${CYAN}Danh sách thiết bị đã scan:${RESET}"
  echo

  nl -w2 -s") " "$DEVICE_FILE"

  pause
}

list_adb_devices() {
  banner
  echo -e "${CYAN}Thiết bị ADB hiện tại:${RESET}"
  echo
  $ADB_BIN devices
  pause
}

edit_device_names() {
  banner

  echo -e "${YELLOW}File tên thiết bị:${RESET}"
  echo "$NAME_FILE"
  echo
  echo "Định dạng:"
  echo "K201|10.48.154.201:5555"
  echo "K202|10.48.154.202:5555"
  echo

  if has_cmd nano; then
    nano "$NAME_FILE"
  elif has_cmd vi; then
    vi "$NAME_FILE"
  else
    echo -e "${RED}Không có nano/vi. Tạo file mẫu...${RESET}"
    touch "$NAME_FILE"
    cat "$NAME_FILE"
    pause
  fi
}

batch_open_url() {
  banner
  read -rp "Nhập URL muốn mở trên tất cả thiết bị: " URL
  [ -z "$URL" ] && return

  $ADB_BIN devices | awk 'NR>1 && $2=="device"{print $1}' | while read -r serial; do
    (
      $ADB_BIN -s "$serial" shell am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1
      echo -e "${GREEN}OPEN URL → $serial${RESET}"
    ) &
  done

  wait
  pause
}

batch_open_app() {
  banner
  read -rp "Nhập package app, ví dụ com.zing.zalo: " PKG
  [ -z "$PKG" ] && return

  $ADB_BIN devices | awk 'NR>1 && $2=="device"{print $1}' | while read -r serial; do
    (
      $ADB_BIN -s "$serial" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
      echo -e "${GREEN}OPEN APP → $serial${RESET}"
    ) &
  done

  wait
  pause
}

batch_install_apk() {
  banner
  read -rp "Nhập đường dẫn APK trên tablet: " APK

  if [ ! -f "$APK" ]; then
    echo -e "${RED}Không thấy file APK.${RESET}"
    pause
    return
  fi

  $ADB_BIN devices | awk 'NR>1 && $2=="device"{print $1}' | while read -r serial; do
    (
      echo -e "${YELLOW}INSTALL → $serial${RESET}"
      $ADB_BIN -s "$serial" install -r "$APK" >/dev/null 2>&1

      if [ $? -eq 0 ]; then
        echo -e "${GREEN}INSTALL OK → $serial${RESET}"
      else
        echo -e "${RED}INSTALL FAIL → $serial${RESET}"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge 4 ]; do
      sleep 0.2
    done
  done

  wait
  pause
}

batch_push_file() {
  banner

  if [ -f "$LAST_FILE" ]; then
    LAST_PATH="$(cat "$LAST_FILE")"
    echo -e "${YELLOW}File lần trước:${RESET} $LAST_PATH"
    read -rp "Enter để dùng lại, hoặc nhập file mới: " FILE
    [ -z "$FILE" ] && FILE="$LAST_PATH"
  else
    read -rp "Nhập đường dẫn video/file trên tablet: " FILE
  fi

  if [ ! -f "$FILE" ]; then
    echo -e "${RED}Không thấy file.${RESET}"
    pause
    return
  fi

  echo "$FILE" > "$LAST_FILE"

  BASENAME="$(basename "$FILE")"
  REMOTE="/sdcard/Download/$BASENAME"

  echo
  echo -e "${CYAN}Đẩy file tới /sdcard/Download/$BASENAME${RESET}"
  echo

  $ADB_BIN devices | awk 'NR>1 && $2=="device"{print $1}' | while read -r serial; do
    (
      echo -e "${YELLOW}PUSH → $serial${RESET}"

      $ADB_BIN -s "$serial" push "$FILE" "$REMOTE"

      if [ $? -eq 0 ]; then
        echo -e "${GREEN}PUSH OK → $serial${RESET}"
      else
        echo -e "${RED}PUSH FAIL → $serial${RESET}"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge 3 ]; do
      sleep 0.2
    done
  done

  wait
  pause
}

batch_push_and_open_video() {
  banner

  if [ -f "$LAST_FILE" ]; then
    LAST_PATH="$(cat "$LAST_FILE")"
    echo -e "${YELLOW}Video/File lần trước:${RESET} $LAST_PATH"
    read -rp "Enter để dùng lại, hoặc nhập file mới: " FILE
    [ -z "$FILE" ] && FILE="$LAST_PATH"
  else
    read -rp "Nhập đường dẫn video/file trên tablet: " FILE
  fi

  if [ ! -f "$FILE" ]; then
    echo -e "${RED}Không thấy file.${RESET}"
    pause
    return
  fi

  echo "$FILE" > "$LAST_FILE"

  BASENAME="$(basename "$FILE")"
  REMOTE="/sdcard/Download/$BASENAME"

  $ADB_BIN devices | awk 'NR>1 && $2=="device"{print $1}' | while read -r serial; do
    (
      echo -e "${YELLOW}PUSH → $serial${RESET}"

      $ADB_BIN -s "$serial" push "$FILE" "$REMOTE"

      if [ $? -eq 0 ]; then
        echo -e "${GREEN}PUSH OK → $serial${RESET}"

        $ADB_BIN -s "$serial" shell am start \
          -a android.intent.action.VIEW \
          -d "file://$REMOTE" \
          -t "video/*" >/dev/null 2>&1

        echo -e "${GREEN}OPEN VIDEO → $serial${RESET}"
      else
        echo -e "${RED}PUSH FAIL → $serial${RESET}"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge 3 ]; do
      sleep 0.2
    done
  done

  wait
  pause
}

list_remote_videos_common() {
  banner

  DEVICES="$($ADB_BIN devices | awk 'NR>1 && $2=="device"{print $1}')"

  if [ -z "$DEVICES" ]; then
    echo -e "${RED}Chưa có thiết bị ADB connected.${RESET}"
    pause
    return
  fi

  TMP="$APP_DIR/video_votes.tmp"
  > "$TMP"

  COUNT=0

  echo -e "${YELLOW}Đang đọc /sdcard/Download trên các thiết bị...${RESET}"
  echo

  for serial in $DEVICES; do
    COUNT=$((COUNT + 1))
    (
      $ADB_BIN -s "$serial" shell 'ls -1 /sdcard/Download 2>/dev/null' | \
      tr -d '\r' | \
      grep -Ei '\.(mp4|mkv|avi|mov|m4v|3gp|webm)$' | \
      sort -u >> "$TMP"
    ) &
  done

  wait

  if [ ! -s "$TMP" ]; then
    echo -e "${RED}Không tìm thấy video nào.${RESET}"
    pause
    return
  fi

  REQUIRED=$(( (COUNT * COMMON_THRESHOLD_PERCENT + 99) / 100 ))

  echo -e "${CYAN}Video xuất hiện trên ít nhất $COMMON_THRESHOLD_PERCENT% thiết bị.${RESET}"
  echo -e "${CYAN}Tổng thiết bị: $COUNT | Ngưỡng: $REQUIRED thiết bị${RESET}"
  echo

  sort "$TMP" | uniq -c | sort -nr | awk -v req="$REQUIRED" '$1 >= req {print $2}'

  echo
  read -rp "Nhập tên video muốn mở trên tất cả thiết bị, bỏ trống để thoát: " VIDEO

  [ -z "$VIDEO" ] && return

  REMOTE="/sdcard/Download/$VIDEO"

  for serial in $DEVICES; do
    (
      $ADB_BIN -s "$serial" shell am start \
        -a android.intent.action.VIEW \
        -d "file://$REMOTE" \
        -t "video/*" >/dev/null 2>&1

      echo -e "${GREEN}OPEN $VIDEO → $serial${RESET}"
    ) &
  done

  wait
  pause
}

batch_reboot() {
  banner

  read -rp "Gõ YES để reboot tất cả thiết bị ADB: " OK
  [ "$OK" != "YES" ] && return

  $ADB_BIN devices | awk 'NR>1 && $2=="device"{print $1}' | while read -r serial; do
    (
      $ADB_BIN -s "$serial" reboot >/dev/null 2>&1
      echo -e "${YELLOW}REBOOT → $serial${RESET}"
    ) &
  done

  wait
  pause
}

dashboard_summary() {
  banner

  echo -e "${CYAN}Trạng thái LabDroid Gateway${RESET}"
  line
  echo "App dir: $APP_DIR"
  echo "Device file: $DEVICE_FILE"
  echo "Name file: $NAME_FILE"
  echo
  echo "ADB:"
  $ADB_BIN version 2>/dev/null | head -n1 || echo "adb chưa hoạt động"
  echo
  echo "Connected:"
  $ADB_BIN devices | grep ":5555" || true
  echo
  echo -e "${GREEN}Tổng connected: $(adb_connected_count)${RESET}"

  pause
}

menu() {
  auto_install_missing

  while true; do
    banner
    echo "1) Scan subnet tùy chọn"
    echo "2) Scan + connect subnet tùy chọn"
    echo "3) Scan nhanh 10.48.154 + 10.48.155"
    echo "4) Connect lại danh sách đã scan"
    echo "5) Xem adb devices"
    echo "6) Xem danh sách đã scan"
    echo "7) Sửa tên thiết bị"
    echo "8) Mở URL hàng loạt"
    echo "9) Mở app hàng loạt"
    echo "10) Cài APK hàng loạt"
    echo "11) Push file hàng loạt"
    echo "12) Push video/file và mở video"
    echo "13) Tìm video chung trên /sdcard/Download và mở"
    echo "14) Reboot hàng loạt"
    echo "15) Dashboard trạng thái"
    echo "0) Thoát"
    echo
    read -rp "Chọn: " c

    case "$c" in
      1) scan_custom_subnets ;;
      2) scan_and_connect_custom_subnets ;;
      3) quick_scan_154_155 ;;
      4) connect_saved_devices ;;
      5) list_adb_devices ;;
      6) list_saved_devices ;;
      7) edit_device_names ;;
      8) batch_open_url ;;
      9) batch_open_app ;;
      10) batch_install_apk ;;
      11) batch_push_file ;;
      12) batch_push_and_open_video ;;
      13) list_remote_videos_common ;;
      14) batch_reboot ;;
      15) dashboard_summary ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

menu
