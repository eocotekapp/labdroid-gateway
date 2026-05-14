#!/usr/bin/env bash

PORT=5555
ADB_BIN="${ADB_BIN:-adb}"

APP_DIR="$HOME/.labdroid"
DEVICE_FILE="$APP_DIR/devices.txt"
NAME_FILE="$APP_DIR/names.txt"
CACHE_DIR="$APP_DIR/cache"
TMP_DIR="$APP_DIR/tmp"
LAST_FILE="$APP_DIR/last_file.txt"
UPLOAD_WEB_URL="https://thong-url-1.onrender.com"

COMMON_THRESHOLD_PERCENT=60

mkdir -p "$APP_DIR" "$CACHE_DIR" "$TMP_DIR"

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

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

banner() {
  clear
  echo -e "${MAGENTA}════════════════════════════════════════════════════════════${RESET}"
  echo -e "   ${GREEN}ADB${RESET} ${MAGENTA}TOOL${RESET} ${CYAN}MENU${RESET} - ${WHITE}LabDroid Gateway${RESET} 🤗"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${RESET}"
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
  MISSING=""

  for c in bash adb timeout awk grep sed sort wc seq; do
    if ! has_cmd "$c"; then
      MISSING="$MISSING $c"
    fi
  done

  if [ -z "$MISSING" ]; then
    return
  fi

  banner
  echo -e "${YELLOW}Thiếu addon:${RESET} $MISSING"
  echo -e "${YELLOW}Đang thử tự cài...${RESET}"
  echo

  ENV_TYPE="$(detect_env)"

  case "$ENV_TYPE" in
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
      echo -e "${RED}Không nhận diện được môi trường để tự cài.${RESET}"
      echo "Nếu là ADBify, hãy đảm bảo đã có adb, bash, timeout, curl/wget."
      pause
      ;;
  esac
}

check_port_5555() {
  local ip="$1"
  timeout 1 bash -c "echo >/dev/tcp/$ip/$PORT" >/dev/null 2>&1
}

adb_connected_devices() {
  $ADB_BIN devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}'
}

adb_connected_count() {
  adb_connected_devices | wc -l | tr -d ' '
}

normalize_serial() {
  local s="$1"
  if echo "$s" | grep -q ':'; then
    echo "$s"
  else
    echo "$s:$PORT"
  fi
}

get_name() {
  local serial="$1"
  if [ -f "$NAME_FILE" ]; then
    grep "|$serial$" "$NAME_FILE" 2>/dev/null | head -n1 | cut -d'|' -f1
  fi
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
  local target="$1"
  echo "$target" >> "$DEVICE_FILE"
}

dedupe_devices() {
  [ -f "$DEVICE_FILE" ] && sort -u "$DEVICE_FILE" -o "$DEVICE_FILE"
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

select_devices() {
  local devices
  devices="$(adb_connected_devices)"

  if [ -z "$devices" ]; then
    echo ""
    return
  fi

  local list_file="$TMP_DIR/select_devices.txt"
  echo "$devices" > "$list_file"

  echo
  echo -e "${CYAN}Thiết bị đang connect:${RESET}"
  echo

  local idx=1
  while read -r serial; do
    echo "$idx) $(display_device "$serial")"
    idx=$((idx + 1))
  done < "$list_file"

  echo
  echo "a) Tất cả"
  echo
  read -rp "Chọn thiết bị, ví dụ 1 2 5 hoặc a: " choice

  if [ "$choice" = "a" ] || [ "$choice" = "A" ] || [ -z "$choice" ]; then
    cat "$list_file"
    return
  fi

  for n in $choice; do
    sed -n "${n}p" "$list_file"
  done | grep -v '^$' | sort -u
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
  echo -e "${YELLOW}Đang scan và adb connect 2 lần...${RESET}"
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

list_adb_devices() {
  banner
  echo -e "${CYAN}Thiết bị ADB hiện tại:${RESET}"
  echo

  local idx=1
  adb_connected_devices | while read -r serial; do
    echo "$idx) $(display_device "$serial")"
    idx=$((idx + 1))
  done

  echo
  echo -e "${GREEN}Tổng connected: $(adb_connected_count)${RESET}"
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

  echo
  TARGETS="$(select_devices)"
  [ -z "$TARGETS" ] && echo -e "${RED}Không có thiết bị nào.${RESET}" && pause && return

  BASENAME="$(basename "$FILE")"
  REMOTE="/sdcard/Download/$BASENAME"

  echo
  echo -e "${CYAN}Đẩy file tới /sdcard/Download/$BASENAME${RESET}"
  echo

  echo "$TARGETS" | while read -r serial; do
    (
      echo -e "${YELLOW}PUSH → $(display_device "$serial")${RESET}"
      $ADB_BIN -s "$serial" push "$FILE" "$REMOTE"

      if [ $? -eq 0 ]; then
        echo -e "${GREEN}PUSH OK → $(display_device "$serial")${RESET}"
      else
        echo -e "${RED}PUSH FAIL → $(display_device "$serial")${RESET}"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge 3 ]; do
      sleep 0.2
    done
  done

  wait
  pause
}

batch_open_url() {
  banner
  read -rp "Nhập URL muốn mở trên thiết bị: " URL
  [ -z "$URL" ] && return

  TARGETS="$(select_devices)"
  [ -z "$TARGETS" ] && echo -e "${RED}Không có thiết bị nào.${RESET}" && pause && return

  echo "$TARGETS" | while read -r serial; do
    (
      $ADB_BIN -s "$serial" shell am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1
      echo -e "${GREEN}OPEN URL → $(display_device "$serial")${RESET}"
    ) &
  done

  wait
  pause
}

batch_open_app() {
  banner
  read -rp "Nhập package app, ví dụ com.zing.zalo: " PKG
  [ -z "$PKG" ] && return

  TARGETS="$(select_devices)"
  [ -z "$TARGETS" ] && echo -e "${RED}Không có thiết bị nào.${RESET}" && pause && return

  echo "$TARGETS" | while read -r serial; do
    (
      $ADB_BIN -s "$serial" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
      echo -e "${GREEN}OPEN APP → $(display_device "$serial")${RESET}"
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

  TARGETS="$(select_devices)"
  [ -z "$TARGETS" ] && echo -e "${RED}Không có thiết bị nào.${RESET}" && pause && return

  echo "$TARGETS" | while read -r serial; do
    (
      echo -e "${YELLOW}INSTALL → $(display_device "$serial")${RESET}"
      $ADB_BIN -s "$serial" install -r "$APK" >/dev/null 2>&1

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

batch_home() {
  banner

  TARGETS="$(select_devices)"
  [ -z "$TARGETS" ] && echo -e "${RED}Không có thiết bị nào.${RESET}" && pause && return

  echo "$TARGETS" | while read -r serial; do
    (
      $ADB_BIN -s "$serial" shell input keyevent KEYCODE_HOME >/dev/null 2>&1
      echo -e "${GREEN}HOME → $(display_device "$serial")${RESET}"
    ) &
  done

  wait
  pause
}

get_remote_videos() {
  local serial="$1"

  $ADB_BIN -s "$serial" shell 'find /sdcard/Download -maxdepth 1 -type f 2>/dev/null' | \
    tr -d '\r' | \
    sed 's#^/sdcard/Download/##' | \
    grep -Ei '\.(mp4|mkv|avi|mov|m4v|3gp|webm)$' | \
    sort -u
}

build_common_video_list() {
  local devices
  devices="$(adb_connected_devices)"

  local vote_file="$TMP_DIR/video_votes.txt"
  local map_file="$TMP_DIR/video_map.txt"
  local common_file="$TMP_DIR/common_videos.txt"

  > "$vote_file"
  > "$map_file"
  > "$common_file"

  local count=0

  echo -e "${YELLOW}Đang quét video trong /sdcard/Download trên tất cả thiết bị...${RESET}"
  echo

  for serial in $devices; do
    count=$((count + 1))
    (
      vids="$(get_remote_videos "$serial")"
      if [ -n "$vids" ]; then
        echo "$vids" | while read -r v; do
          echo "$v" >> "$vote_file"
          echo "$v|$serial" >> "$map_file"
        done
      fi
      echo -e "${GREEN}DONE → $(display_device "$serial")${RESET}"
    ) &
  done

  wait

  if [ "$count" -eq 0 ]; then
    echo -e "${RED}Chưa có thiết bị ADB connected.${RESET}"
    return 1
  fi

  if [ ! -s "$vote_file" ]; then
    echo -e "${RED}Không tìm thấy video nào.${RESET}"
    return 1
  fi

  local required
  required=$(( (count * COMMON_THRESHOLD_PERCENT + 99) / 100 ))

  sort "$vote_file" | uniq -c | sort -nr | awk -v req="$required" '$1 >= req { $1=$1; print }' > "$TMP_DIR/common_raw.txt"

  if [ ! -s "$TMP_DIR/common_raw.txt" ]; then
    echo -e "${RED}Không có video nào đạt ngưỡng $COMMON_THRESHOLD_PERCENT%.${RESET}"
    echo -e "${YELLOW}Tổng thiết bị: $count | Cần tối thiểu: $required thiết bị có cùng video.${RESET}"
    return 1
  fi

  awk '{$1=""; sub(/^ /,""); print}' "$TMP_DIR/common_raw.txt" > "$common_file"

  echo
  echo -e "${CYAN}Video đạt ngưỡng $COMMON_THRESHOLD_PERCENT%:${RESET}"
  echo -e "${CYAN}Tổng thiết bị: $count | Ngưỡng: $required thiết bị${RESET}"
  echo

  local idx=1
  while read -r video; do
    have_count="$(grep -Fx "$video" "$vote_file" | wc -l | tr -d ' ')"
    echo "$idx) [$have_count/$count] $video"
    idx=$((idx + 1))
  done < "$common_file"

  return 0
}

choose_common_video() {
  build_common_video_list || return 1

  echo
  read -rp "Chọn số video: " num

  if ! echo "$num" | grep -Eq '^[0-9]+$'; then
    echo -e "${RED}Số không hợp lệ.${RESET}"
    return 1
  fi

  sed -n "${num}p" "$TMP_DIR/common_videos.txt"
}

open_video_on_targets() {
  local video="$1"
  local targets="$2"
  local remote="/sdcard/Download/$video"

  echo "$targets" | while read -r serial; do
    (
      $ADB_BIN -s "$serial" shell am start \
        -a android.intent.action.VIEW \
        -d "file://$remote" \
        -t "video/*" >/dev/null 2>&1

      echo -e "${GREEN}OPEN VIDEO → $(display_device "$serial")${RESET}"
    ) &
  done

  wait
}

feature_5_open_common_video() {
  banner

  video="$(choose_common_video)" || { pause; return; }

  echo
  echo -e "${YELLOW}Đã chọn:${RESET} $video"
  echo

  TARGETS="$(select_devices)"
  [ -z "$TARGETS" ] && echo -e "${RED}Không có thiết bị nào.${RESET}" && pause && return

  open_video_on_targets "$video" "$TARGETS"

  pause
}

device_has_video() {
  local serial="$1"
  local video="$2"

  $ADB_BIN -s "$serial" shell "ls '/sdcard/Download/$video'" >/dev/null 2>&1
}

find_source_device_for_video() {
  local video="$1"

  adb_connected_devices | while read -r serial; do
    if device_has_video "$serial" "$video"; then
      echo "$serial"
      break
    fi
  done
}

safe_filename() {
  echo "$1" | sed 's#[/\\:*?"<>|]#_#g'
}

feature_6_sync_common_video() {
  banner

  video="$(choose_common_video)" || { pause; return; }

  echo
  echo -e "${YELLOW}Đã chọn:${RESET} $video"

  source_serial="$(find_source_device_for_video "$video")"

  if [ -z "$source_serial" ]; then
    echo -e "${RED}Không tìm được máy nguồn có video này.${RESET}"
    pause
    return
  fi

  echo -e "${CYAN}Máy nguồn:${RESET} $(display_device "$source_serial")"

  local cache_name
  cache_name="$(safe_filename "$video")"
  local local_file="$CACHE_DIR/$cache_name"

  if [ -f "$local_file" ]; then
    echo -e "${GREEN}Cache đã có:${RESET} $local_file"
  else
    echo -e "${YELLOW}Đang pull video về cache...${RESET}"
    $ADB_BIN -s "$source_serial" pull "/sdcard/Download/$video" "$local_file"

    if [ $? -ne 0 ] || [ ! -f "$local_file" ]; then
      echo -e "${RED}Pull thất bại.${RESET}"
      pause
      return
    fi
  fi

  echo
  TARGETS="$(select_devices)"
  [ -z "$TARGETS" ] && echo -e "${RED}Không có thiết bị nào.${RESET}" && pause && return

  echo
  read -rp "Bỏ qua máy đã có video này? [Y/n]: " skip_have
  [ -z "$skip_have" ] && skip_have="Y"

  echo
  read -rp "Sau khi đồng bộ có phát luôn không? [y/N]: " play_now

  echo
  echo -e "${YELLOW}Đang đồng bộ video sang thiết bị đã chọn...${RESET}"
  echo

  echo "$TARGETS" | while read -r serial; do
    (
      if echo "$skip_have" | grep -qi '^y'; then
        if device_has_video "$serial" "$video"; then
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

          echo -e "${GREEN}PLAY → $(display_device "$serial")${RESET}"
        fi
      else
        echo -e "${RED}PUSH FAIL → $(display_device "$serial")${RESET}"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge 3 ]; do
      sleep 0.2
    done
  done

  wait
  pause
}

feature_7_names_manager() {
  while true; do
    banner
    echo -e "${CYAN}Quản lý tên máy/IP${RESET}"
    line
    echo "1) Xem danh sách tên máy/IP"
    echo "2) Thêm hoặc sửa tên máy"
    echo "3) Import nhanh từ thiết bị đang connect"
    echo "4) Xoá một dòng theo số thứ tự"
    echo "5) Mở file bằng nano/vi"
    echo "0) Quay lại"
    echo
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
        echo "IP/serial: 10.48.154.201:5555"
        echo
        read -rp "Nhập tên máy: " name
        read -rp "Nhập IP/serial: " serial
        serial="$(normalize_serial "$serial")"

        if [ -z "$name" ] || [ -z "$serial" ]; then
          echo -e "${RED}Thiếu tên hoặc IP.${RESET}"
          pause
          continue
        fi

        grep -v "|$serial$" "$NAME_FILE" 2>/dev/null > "$TMP_DIR/names_new.txt" || true
        echo "$name|$serial" >> "$TMP_DIR/names_new.txt"
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

        for serial in $devices; do
          old_name="$(get_name "$serial")"
          if [ -n "$old_name" ]; then
            echo -e "${CYAN}Đã có:${RESET} $old_name | $serial"
            continue
          fi

          echo
          echo -e "${YELLOW}Thiết bị:${RESET} $serial"
          model="$($ADB_BIN -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
          brand="$($ADB_BIN -s "$serial" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
          echo "Model: $brand $model"
          read -rp "Đặt tên cho máy này, bỏ trống để skip: " name

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
          echo -e "${RED}Chưa có danh sách.${RESET}"
          pause
          continue
        fi

        nl -w2 -s") " "$NAME_FILE"
        echo
        read -rp "Nhập số dòng muốn xoá: " n

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
        banner
        touch "$NAME_FILE"
        if has_cmd nano; then
          nano "$NAME_FILE"
        elif has_cmd vi; then
          vi "$NAME_FILE"
        else
          echo -e "${RED}Không có nano/vi.${RESET}"
          echo "File: $NAME_FILE"
          pause
        fi
        ;;
      0)
        return
        ;;
      *)
        ;;
    esac
  done
}

download_file_url() {
  local url="$1"
  local out="$2"

  if has_cmd curl; then
    curl -L --progress-bar "$url" -o "$out"
  elif has_cmd wget; then
    wget -O "$out" "$url"
  else
    echo -e "${RED}Thiếu curl/wget.${RESET}"
    return 1
  fi
}

guess_filename_from_url() {
  local url="$1"
  basename "${url%%\?*}" | sed 's/%20/ /g'
}

feature_8_download_url_cache_push() {
  banner

  echo -e "${CYAN}Tải video từ URL direct vào cache rồi push sang thiết bị${RESET}"
  line
  read -rp "Nhập URL direct: " URL

  if [ -z "$URL" ]; then
    echo -e "${RED}Chưa nhập URL.${RESET}"
    pause
    return
  fi

  default_name="$(guess_filename_from_url "$URL")"

  if [ -z "$default_name" ] || ! echo "$default_name" | grep -q '\.'; then
    default_name="video_$(date +%Y%m%d_%H%M%S).mp4"
  fi

  echo
  echo -e "${YELLOW}Tên gợi ý:${RESET} $default_name"
  read -rp "Nhập tên file mới, Enter để giữ nguyên: " new_name

  [ -z "$new_name" ] && new_name="$default_name"

  new_name="$(safe_filename "$new_name")"
  local_file="$CACHE_DIR/$new_name"

  echo
  echo -e "${YELLOW}Đang tải về cache:${RESET} $local_file"
  download_file_url "$URL" "$local_file"

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

  read -rp "Có push sang thiết bị luôn không? [Y/n]: " do_push
  [ -z "$do_push" ] && do_push="Y"

  if ! echo "$do_push" | grep -qi '^y'; then
    pause
    return
  fi

  TARGETS="$(select_devices)"
  [ -z "$TARGETS" ] && echo -e "${RED}Không có thiết bị nào.${RESET}" && pause && return

  read -rp "Push xong có mở video luôn không? [y/N]: " play_now

  remote="/sdcard/Download/$new_name"

  echo "$TARGETS" | while read -r serial; do
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

          echo -e "${GREEN}PLAY → $(display_device "$serial")${RESET}"
        fi
      else
        echo -e "${RED}PUSH FAIL → $(display_device "$serial")${RESET}"
      fi
    ) &

    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge 3 ]; do
      sleep 0.2
    done
  done

  wait
  pause
}

feature_9_open_upload_web() {
  banner

  echo -e "${CYAN}Mở web upload video lấy URL direct${RESET}"
  echo
  echo "$UPLOAD_WEB_URL"
  echo

  if has_cmd termux-open-url; then
    termux-open-url "$UPLOAD_WEB_URL"
    echo -e "${GREEN}Đã mở bằng termux-open-url.${RESET}"
  elif has_cmd xdg-open; then
    xdg-open "$UPLOAD_WEB_URL" >/dev/null 2>&1
    echo -e "${GREEN}Đã mở bằng xdg-open.${RESET}"
  elif has_cmd am; then
    am start -a android.intent.action.VIEW -d "$UPLOAD_WEB_URL" >/dev/null 2>&1
    echo -e "${GREEN}Đã mở bằng Android intent.${RESET}"
  else
    echo -e "${YELLOW}Không tự mở được. Copy link này vào trình duyệt:${RESET}"
    echo "$UPLOAD_WEB_URL"
  fi

  pause
}

batch_reboot() {
  banner

  TARGETS="$(select_devices)"
  [ -z "$TARGETS" ] && echo -e "${RED}Không có thiết bị nào.${RESET}" && pause && return

  echo
  read -rp "Gõ YES để reboot thiết bị đã chọn: " OK
  [ "$OK" != "YES" ] && return

  echo "$TARGETS" | while read -r serial; do
    (
      $ADB_BIN -s "$serial" reboot >/dev/null 2>&1
      echo -e "${YELLOW}REBOOT → $(display_device "$serial")${RESET}"
    ) &
  done

  wait
  pause
}

cache_manager() {
  while true; do
    banner
    echo -e "${CYAN}Cache video/file${RESET}"
    line
    echo "Thư mục cache: $CACHE_DIR"
    echo
    echo "1) Xem file cache"
    echo "2) Push file trong cache"
    echo "3) Xoá cache"
    echo "0) Quay lại"
    echo
    read -rp "Chọn: " c

    case "$c" in
      1)
        banner
        ls -lh "$CACHE_DIR"
        pause
        ;;
      2)
        banner
        files="$(find "$CACHE_DIR" -maxdepth 1 -type f 2>/dev/null | sort)"
        if [ -z "$files" ]; then
          echo -e "${RED}Cache trống.${RESET}"
          pause
          continue
        fi

        echo "$files" > "$TMP_DIR/cache_files.txt"
        nl -w2 -s") " "$TMP_DIR/cache_files.txt"
        echo
        read -rp "Chọn số file: " n
        file="$(sed -n "${n}p" "$TMP_DIR/cache_files.txt")"

        if [ ! -f "$file" ]; then
          echo -e "${RED}File không hợp lệ.${RESET}"
          pause
          continue
        fi

        TARGETS="$(select_devices)"
        [ -z "$TARGETS" ] && echo -e "${RED}Không có thiết bị nào.${RESET}" && pause && continue

        read -rp "Push xong có mở video không? [y/N]: " play_now

        name="$(basename "$file")"
        remote="/sdcard/Download/$name"

        echo "$TARGETS" | while read -r serial; do
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
              fi
            fi
          ) &
        done

        wait
        pause
        ;;
      3)
        banner
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

  echo -e "${CYAN}Trạng thái LabDroid Gateway${RESET}"
  line
  echo "App dir: $APP_DIR"
  echo "Cache dir: $CACHE_DIR"
  echo "Device file: $DEVICE_FILE"
  echo "Name file: $NAME_FILE"
  echo
  echo "ADB:"
  $ADB_BIN version 2>/dev/null | head -n1 || echo "adb chưa hoạt động"
  echo
  echo "Connected:"
  echo

  local idx=1
  adb_connected_devices | while read -r serial; do
    model="$($ADB_BIN -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
    brand="$($ADB_BIN -s "$serial" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
    battery="$($ADB_BIN -s "$serial" shell dumpsys battery 2>/dev/null | awk -F': ' '/level/ {print $2; exit}' | tr -d '\r')"
    echo "$idx) $(display_device "$serial") | $brand $model | Pin: ${battery:-?}%"
    idx=$((idx + 1))
  done

  echo
  echo -e "${GREEN}Tổng connected: $(adb_connected_count)${RESET}"

  pause
}

main_menu() {
  auto_install_missing

  while true; do
    banner
    echo -e "1)  🔗 ${CYAN}Lọc IP mở 5555 rồi connect 2 lần${RESET}"
    echo -e "2)  🔗 ${GREEN}Connect IP thủ công / subnet tuỳ chọn${RESET}"
    echo -e "3)  📋 ${YELLOW}Xem thiết bị đang connect${RESET}"
    echo -e "4)  🖼️  ${MAGENTA}Push video/file lên thiết bị${RESET}"
    echo -e "5)  🎬 ${CYAN}Xem video đạt ngưỡng và chọn mở luôn${RESET}"
    echo -e "6)  🔄 ${GREEN}Chọn video đạt ngưỡng rồi tự đồng bộ + phát${RESET}"
    echo -e "7)  🗂️  ${YELLOW}Xem / thêm danh sách tên máy/IP${RESET}"
    echo -e "8)  🌐 ${CYAN}Tải video từ URL vào cache rồi push${RESET}"
    echo -e "9)  🌍 ${BLUE}Mở web upload lấy URL direct${RESET}"
    echo -e "10) 🏠 ${CYAN}Đưa thiết bị đã chọn về Home${RESET}"
    echo -e "11) 📦 ${YELLOW}Cài APK hàng loạt${RESET}"
    echo -e "12) 🚀 ${GREEN}Mở app hàng loạt${RESET}"
    echo -e "13) 🔗 ${BLUE}Mở URL hàng loạt${RESET}"
    echo -e "14) 🧹 ${MAGENTA}Quản lý cache${RESET}"
    echo -e "15) 📊 ${CYAN}Dashboard trạng thái${RESET}"
    echo -e "16) 🔁 ${YELLOW}Connect lại danh sách đã scan${RESET}"
    echo -e "17) ⚡ ${GREEN}Scan nhanh 10.48.154 + 10.48.155${RESET}"
    echo -e "18) 🔄 ${RED}Reboot thiết bị đã chọn${RESET}"
    echo -e "0)  ✖ ${RED}Thoát${RESET}"
    line
    read -rp "Chọn: " c

    case "$c" in
      1) scan_and_connect_custom_subnets ;;
      2) scan_and_connect_custom_subnets ;;
      3) list_adb_devices ;;
      4) batch_push_file ;;
      5) feature_5_open_common_video ;;
      6) feature_6_sync_common_video ;;
      7) feature_7_names_manager ;;
      8) feature_8_download_url_cache_push ;;
      9) feature_9_open_upload_web ;;
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