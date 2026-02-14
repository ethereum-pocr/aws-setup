#!/bin/bash
# Interactive S3 browser — browse, view, download, upload
# Uses the same arrow-key menu pattern as ssh-connect.sh
# Usage: ./s3-browse.sh [bucket-name]

# Check AWS session validity, login if expired
if ! aws sts get-caller-identity &>/dev/null; then
  echo "AWS session expired or not logged in. Initiating login..."
  aws login
  if [ $? -ne 0 ]; then
    echo "AWS login failed. Exiting."
    exit 1
  fi
fi

# --- Colors and symbols ---
BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"
ARROW="▸"

# --- Arrow-key menu selector ---
# Sets MENU_RESULT to the selected index
menu_select() {
  local title="$1"
  shift
  local options=("$@")
  local count=${#options[@]}
  local selected=0

  tput civis 2>/dev/null

  echo ""
  printf "  ${BOLD}${CYAN}%s${RESET}\n" "$title"
  echo ""

  _draw_menu() {
    local i
    for i in "${!options[@]}"; do
      tput el 2>/dev/null
      if [ "$i" -eq "$selected" ]; then
        printf "  ${GREEN}${ARROW} %s${RESET}\n" "${options[$i]}"
      else
        printf "    ${DIM}%s${RESET}\n" "${options[$i]}"
      fi
    done
  }

  _draw_menu

  while true; do
    read -rsn1 _keypress
    case "$_keypress" in
      $'\x1b')
        read -rsn2 seq
        case "$seq" in
          '[A') [ $selected -gt 0 ] && selected=$((selected - 1)) ;;
          '[B') [ $selected -lt $((count - 1)) ] && selected=$((selected + 1)) ;;
        esac
        ;;
      '') break ;;
    esac
    tput cuu "$count" 2>/dev/null
    _draw_menu
  done

  tput cnorm 2>/dev/null
  MENU_RESULT=$selected
}

# --- Multi-select menu ---
# Sets MULTI_RESULTS as an array of selected indices
menu_multi_select() {
  local title="$1"
  shift
  local options=("$@")
  local count=${#options[@]}
  local selected=0
  local checked=()
  for i in "${!options[@]}"; do checked[$i]=0; done

  tput civis 2>/dev/null

  echo ""
  printf "  ${BOLD}${CYAN}%s${RESET}\n" "$title"
  printf "  ${DIM}Space to toggle, Enter to confirm${RESET}\n"
  echo ""

  _draw_multi() {
    local i
    for i in "${!options[@]}"; do
      tput el 2>/dev/null
      local mark="○"
      [ "${checked[$i]}" -eq 1 ] && mark="●"
      if [ "$i" -eq "$selected" ]; then
        printf "  ${GREEN}${ARROW} %s %s${RESET}\n" "$mark" "${options[$i]}"
      else
        printf "    ${DIM}%s %s${RESET}\n" "$mark" "${options[$i]}"
      fi
    done
  }

  _draw_multi

  while true; do
    read -rsn1 _keypress
    case "$_keypress" in
      $'\x1b')
        read -rsn2 seq
        case "$seq" in
          '[A') [ $selected -gt 0 ] && selected=$((selected - 1)) ;;
          '[B') [ $selected -lt $((count - 1)) ] && selected=$((selected + 1)) ;;
        esac
        ;;
      ' ')
        if [ "${checked[$selected]}" -eq 0 ]; then
          checked[$selected]=1
        else
          checked[$selected]=0
        fi
        ;;
      '') break ;;
    esac
    tput cuu "$count" 2>/dev/null
    _draw_multi
  done

  tput cnorm 2>/dev/null

  MULTI_RESULTS=()
  for i in "${!checked[@]}"; do
    [ "${checked[$i]}" -eq 1 ] && MULTI_RESULTS+=("$i")
  done
}

# --- Select a bucket ---
select_bucket() {
  printf "\n  ${CYAN}Listing S3 buckets...${RESET}\n"
  local raw
  raw=$(aws s3 ls 2>/dev/null)
  if [ -z "$raw" ]; then
    printf "  ${RED}No buckets found or access denied.${RESET}\n"
    exit 1
  fi

  local names=()
  while IFS= read -r line; do
    # format: 2024-01-01 12:00:00 bucket-name
    local bname
    bname=$(echo "$line" | awk '{print $3}')
    [ -n "$bname" ] && names+=("$bname")
  done <<< "$raw"

  menu_select "Select a bucket (↑↓ arrows, Enter to confirm)" "${names[@]}"
  BUCKET="${names[$MENU_RESULT]}"
}

# --- List S3 prefix, returns items in ITEMS array ---
# Each item is either "PRE dirname/" (folder) or "date time size filename" (file)
list_prefix() {
  local bucket="$1"
  local prefix="$2"

  ITEMS=()
  ITEM_NAMES=()
  ITEM_TYPES=()

  local raw
  if [ -z "$prefix" ]; then
    raw=$(aws s3 ls "s3://${bucket}/" 2>/dev/null)
  else
    raw=$(aws s3 ls "s3://${bucket}/${prefix}" 2>/dev/null)
  fi

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -q "^[[:space:]]*PRE "; then
      local dirname
      dirname=$(echo "$line" | sed 's/^[[:space:]]*PRE //')
      ITEMS+=("$line")
      ITEM_NAMES+=("$dirname")
      ITEM_TYPES+=("folder")
    else
      # Format: "YYYY-MM-DD HH:MM:SS  SIZE FILENAME..."
      # Strip date, time, and size prefix to get the full filename (handles spaces)
      local fname
      fname=$(echo "$line" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} +[0-9]+ //')
      [ -z "$fname" ] && continue
      ITEMS+=("$line")
      ITEM_NAMES+=("$fname")
      ITEM_TYPES+=("file")
    fi
  done <<< "$raw"
}

# --- Format items for display ---
format_items() {
  local labels=()

  # Add ".." to go up unless at root
  if [ -n "$CURRENT_PREFIX" ]; then
    labels+=("📁 ..")
  fi

  for i in "${!ITEMS[@]}"; do
    if [ "${ITEM_TYPES[$i]}" = "folder" ]; then
      labels+=("📁 ${ITEM_NAMES[$i]}")
    else
      local size
      size=$(echo "${ITEMS[$i]}" | awk '{print $3}')
      labels+=("   ${ITEM_NAMES[$i]}  (${size} bytes)")
    fi
  done

  DISPLAY_LABELS=("${labels[@]}")
}

# --- File action menu ---
file_action() {
  local bucket="$1"
  local key="$2"
  local fname
  fname=$(basename "$key")

  local actions=("View content" "Download to current directory" "Delete file" "Back")
  menu_select "Action for ${fname}" "${actions[@]}"

  case "$MENU_RESULT" in
    0) # View
      echo ""
      local s3url="s3://${bucket}/${key}"
      printf "  ${CYAN}--- %s ---${RESET}\n" "$s3url"
      local tmpfile
      tmpfile=$(mktemp)
      if aws s3 cp "$s3url" "$tmpfile"; then
        less "$tmpfile"
      else
        printf "  ${RED}Failed to download %s${RESET}\n" "$s3url"
        read -rsn1 -p "  Press any key to continue..."
      fi
      rm -f "$tmpfile"
      ;;
    1) # Download
      echo ""
      printf "  ${CYAN}Downloading %s ...${RESET}\n" "$fname"
      aws s3 cp "s3://${bucket}/${key}" "./${fname}"
      printf "  ${GREEN}Downloaded to ./%s${RESET}\n" "$fname"
      read -rsn1 -p "  Press any key to continue..."
      ;;
    2) # Delete
      echo ""
      printf "  ${RED}${BOLD}Delete s3://%s/%s ?${RESET}\n" "$bucket" "$key"
      read -rp "  Type 'yes' to confirm: " confirm
      if [ "$confirm" = "yes" ]; then
        aws s3 rm "s3://${bucket}/${key}"
        printf "  ${GREEN}Deleted.${RESET}\n"
      else
        printf "  ${DIM}Cancelled.${RESET}\n"
      fi
      read -rsn1 -p "  Press any key to continue..."
      ;;
    3) ;; # Back
  esac
}

# --- Folder action menu ---
folder_action() {
  local bucket="$1"
  local prefix="$2"

  local actions=("Open folder" "Download folder recursively" "Delete folder recursively" "Back")
  menu_select "Action for ${prefix}" "${actions[@]}"

  case "$MENU_RESULT" in
    0) # Open
      CURRENT_PREFIX="${prefix}"
      ;;
    1) # Download recursively
      local dirname
      dirname=$(basename "${prefix%/}")
      echo ""
      printf "  ${CYAN}Downloading s3://%s/%s to ./%s/ ...${RESET}\n" "$bucket" "$prefix" "$dirname"
      aws s3 cp "s3://${bucket}/${prefix}" "./${dirname}/" --recursive
      printf "  ${GREEN}Downloaded to ./%s/${RESET}\n" "$dirname"
      read -rsn1 -p "  Press any key to continue..."
      ;;
    2) # Delete recursively
      echo ""
      printf "  ${RED}${BOLD}Delete ALL contents of s3://%s/%s ?${RESET}\n" "$bucket" "$prefix"
      read -rp "  Type 'yes' to confirm: " confirm
      if [ "$confirm" = "yes" ]; then
        aws s3 rm "s3://${bucket}/${prefix}" --recursive
        printf "  ${GREEN}Deleted.${RESET}\n"
      else
        printf "  ${DIM}Cancelled.${RESET}\n"
      fi
      read -rsn1 -p "  Press any key to continue..."
      ;;
    3) ;; # Back
  esac
}

# --- Upload menu ---
upload_menu() {
  local bucket="$1"
  local prefix="$2"

  echo ""
  printf "  ${BOLD}${CYAN}Upload to s3://%s/%s${RESET}\n" "$bucket" "$prefix"
  echo ""
  read -rp "  Local path (file or directory): " local_path

  if [ -z "$local_path" ]; then
    return
  fi

  # Expand ~ if present
  local_path="${local_path/#\~/$HOME}"

  if [ ! -e "$local_path" ]; then
    printf "  ${RED}Path not found: %s${RESET}\n" "$local_path"
    read -rsn1 -p "  Press any key to continue..."
    return
  fi

  if [ -d "$local_path" ]; then
    printf "  ${CYAN}Uploading directory %s to s3://%s/%s ...${RESET}\n" "$local_path" "$bucket" "$prefix"
    aws s3 cp "$local_path" "s3://${bucket}/${prefix}" --recursive
  else
    local fname
    fname=$(basename "$local_path")
    printf "  ${CYAN}Uploading %s to s3://%s/%s%s ...${RESET}\n" "$local_path" "$bucket" "$prefix" "$fname"
    aws s3 cp "$local_path" "s3://${bucket}/${prefix}${fname}"
  fi

  printf "  ${GREEN}Upload complete.${RESET}\n"
  read -rsn1 -p "  Press any key to continue..."
}

# --- Batch download ---
batch_download() {
  local bucket="$1"
  local prefix="$2"

  # Collect only files (not folders)
  local file_items=()
  local file_keys=()
  for i in "${!ITEM_TYPES[@]}"; do
    if [ "${ITEM_TYPES[$i]}" = "file" ]; then
      file_items+=("${ITEM_NAMES[$i]}")
      file_keys+=("${prefix}${ITEM_NAMES[$i]}")
    fi
  done

  if [ ${#file_items[@]} -eq 0 ]; then
    printf "\n  ${YELLOW}No files in this location.${RESET}\n"
    read -rsn1 -p "  Press any key to continue..."
    return
  fi

  menu_multi_select "Select files to download (Space to toggle)" "${file_items[@]}"

  if [ ${#MULTI_RESULTS[@]} -eq 0 ]; then
    printf "\n  ${YELLOW}No files selected.${RESET}\n"
    read -rsn1 -p "  Press any key to continue..."
    return
  fi

  echo ""
  for idx in "${MULTI_RESULTS[@]}"; do
    local fname="${file_items[$idx]}"
    local key="${file_keys[$idx]}"
    printf "  ${CYAN}Downloading %s ...${RESET}\n" "$fname"
    aws s3 cp "s3://${bucket}/${key}" "./${fname}"
  done
  printf "  ${GREEN}Downloaded %d file(s).${RESET}\n" "${#MULTI_RESULTS[@]}"
  read -rsn1 -p "  Press any key to continue..."
}

# --- Main browse loop ---
browse() {
  local bucket="$1"
  CURRENT_PREFIX=""

  while true; do
    list_prefix "$bucket" "$CURRENT_PREFIX"
    format_items

    # Add action items at the bottom
    local menu_items=("${DISPLAY_LABELS[@]}")
    menu_items+=("─────────────")
    menu_items+=("⬆ Upload file(s) here")
    menu_items+=("⬇ Batch download files")
    menu_items+=("✕ Quit")

    local location="s3://${bucket}/${CURRENT_PREFIX}"
    menu_select "📂 ${location}" "${menu_items[@]}"

    local choice=$MENU_RESULT
    local offset=0
    [ -n "$CURRENT_PREFIX" ] && offset=1

    # Handle separator and action items
    local item_count=${#DISPLAY_LABELS[@]}
    local sep_idx=$item_count
    local upload_idx=$((item_count + 1))
    local batch_idx=$((item_count + 2))
    local quit_idx=$((item_count + 3))

    if [ "$choice" -eq "$quit_idx" ]; then
      printf "\n  ${DIM}Bye.${RESET}\n"
      break
    elif [ "$choice" -eq "$sep_idx" ]; then
      continue
    elif [ "$choice" -eq "$upload_idx" ]; then
      upload_menu "$bucket" "$CURRENT_PREFIX"
      continue
    elif [ "$choice" -eq "$batch_idx" ]; then
      batch_download "$bucket" "$CURRENT_PREFIX"
      continue
    fi

    # Handle ".." (go up)
    if [ -n "$CURRENT_PREFIX" ] && [ "$choice" -eq 0 ]; then
      # Remove trailing slash, then remove last path component
      local trimmed="${CURRENT_PREFIX%/}"
      if echo "$trimmed" | grep -q '/'; then
        CURRENT_PREFIX="${trimmed%/*}/"
      else
        CURRENT_PREFIX=""
      fi
      continue
    fi

    # Map choice back to ITEMS index
    local item_idx=$((choice - offset))

    if [ "$item_idx" -lt 0 ] || [ "$item_idx" -ge "${#ITEMS[@]}" ]; then
      continue
    fi

    if [ "${ITEM_TYPES[$item_idx]}" = "folder" ]; then
      folder_action "$bucket" "${CURRENT_PREFIX}${ITEM_NAMES[$item_idx]}"
    else
      file_action "$bucket" "${CURRENT_PREFIX}${ITEM_NAMES[$item_idx]}"
    fi
  done
}

# --- Main ---
trap 'tput cnorm 2>/dev/null' EXIT

BUCKET="$1"

if [ -z "$BUCKET" ]; then
  select_bucket
fi

printf "\n  ${GREEN}${BOLD}Browsing s3://%s${RESET}\n" "$BUCKET"
browse "$BUCKET"
