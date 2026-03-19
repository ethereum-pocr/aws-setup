#!/bin/bash
# Interactive SSH connection manager for AWS EC2 instances
# Caches VM info locally and lets you pick instance, user, and key
# Usage: ./ssh-connect.sh [refresh]

# Check AWS session validity, login if expired
if ! aws sts get-caller-identity &>/dev/null; then
  echo "AWS session expired or not logged in. Initiating login..."
  aws login
  if [ $? -ne 0 ]; then
    echo "AWS login failed. Exiting."
    exit 1
  fi
fi

CACHE_FILE="$HOME/.aws-ec2-cache.csv"
# CSV format: name,ip,region,user,ssh_key

# --- Colors and symbols ---
BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
ARROW="▸"

# --- Arrow-key menu selector ---
# Usage: menu_select "Title" result_var "option1" "option2" ...
# Returns selected index via global MENU_RESULT
menu_select() {
  local title="$1"
  shift
  local options=("$@")
  local count=${#options[@]}
  local selected=0

  # Hide cursor
  tput civis 2>/dev/null

  # Print title
  echo ""
  printf "  ${BOLD}${CYAN}%s${RESET}\n" "$title"
  echo ""

  # Draw menu
  local i
  _draw_menu() {
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

  # Read keys
  while true; do
    read -rsn1 key
    case "$key" in
      $'\x1b')  # Escape sequence
        read -rsn2 seq
        case "$seq" in
          '[A') # Up
            [ $selected -gt 0 ] && selected=$((selected - 1))
            ;;
          '[B') # Down
            [ $selected -lt $((count - 1)) ] && selected=$((selected + 1))
            ;;
        esac
        ;;
      '')  # Enter
        break
        ;;
    esac
    # Move cursor up to redraw
    tput cuu "$count" 2>/dev/null
    _draw_menu
  done

  # Show cursor
  tput cnorm 2>/dev/null

  MENU_RESULT=$selected
}

# Guess SSH user from AMI name
guess_user() {
  local ami_name="$1"
  case "$ami_name" in
    ubuntu*|Ubuntu*)       echo "ubuntu" ;;
    debian*|Debian*)       echo "admin" ;;
    amzn*|al2023*|Amazon*) echo "ec2-user" ;;
    RHEL*|rhel*)           echo "ec2-user" ;;
    suse*|SUSE*)           echo "ec2-user" ;;
    fedora*|Fedora*)       echo "fedora" ;;
    bitnami*|Bitnami*)     echo "bitnami" ;;
    *)                     echo "ec2-user" ;;
  esac
}

# Sort cache by instance name (case-insensitive) so menus are predictable.
sort_cache_by_name() {
  [ -f "$CACHE_FILE" ] || return 0
  local tmp_sorted
  tmp_sorted=$(mktemp)
  LC_ALL=C sort -t',' -f -k1,1 -k3,3 -k2,2 "$CACHE_FILE" > "$tmp_sorted"
  mv "$tmp_sorted" "$CACHE_FILE"
}

# 1) Refresh cache from AWS
refresh_cache() {
  echo ""
  printf "  ${CYAN}Fetching EC2 instances from all regions...${RESET}\n"

  local tmp=$(mktemp)

  for region in $(aws ec2 describe-regions --query 'Regions[*].RegionName' --output text); do
    printf "  ${DIM}  scanning %s...${RESET}\r" "$region"
    instances=$(aws ec2 describe-instances \
      --region "$region" \
      --filters "Name=instance-state-name,Values=running" \
      --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],PublicIpAddress,ImageId]' \
      --output text 2>/dev/null)

    while IFS=$'\t' read -r name ip ami_id; do
      if [ -n "$name" ] && [ "$name" != "None" ] && [ -n "$ip" ] && [ "$ip" != "None" ]; then
        ami_name=$(aws ec2 describe-images --image-ids "$ami_id" --region "$region" \
          --query 'Images[0].Name' --output text 2>/dev/null)
        default_user=$(guess_user "$ami_name")

        # Preserve user and key from existing cache if available
        existing=$(grep "^${name}," "$CACHE_FILE" 2>/dev/null)
        if [ -n "$existing" ]; then
          saved_user=$(echo "$existing" | cut -d',' -f4)
          saved_key=$(echo "$existing" | cut -d',' -f5)
          echo "${name},${ip},${region},${saved_user},${saved_key}" >> "$tmp"
        else
          echo "${name},${ip},${region},${default_user}," >> "$tmp"
        fi
      fi
    done <<< "$instances"
  done

  mv "$tmp" "$CACHE_FILE"
  sort_cache_by_name
  tput el 2>/dev/null
  printf "  ${GREEN}Cache updated${RESET} (%s instances)\n" "$(wc -l < "$CACHE_FILE" | tr -d ' ')"
}

# 2) List VMs and select with arrow keys
select_vm() {
  if [ ! -f "$CACHE_FILE" ] || [ ! -s "$CACHE_FILE" ]; then
    echo "Cache is empty. Run with 'refresh' first."
    exit 1
  fi

  sort_cache_by_name

  local labels=()
  local i=1
  while IFS=',' read -r name ip region user key; do
    labels+=("$(printf "%-20s %-16s %-14s %s" "$name" "$ip" "$region" "$user")")
    i=$((i + 1))
  done < "$CACHE_FILE"

  menu_select "Select a VM (↑↓ arrows, Enter to confirm)" "${labels[@]}"

  VM_LINE_NUM=$((MENU_RESULT + 1))
  VM_LINE=$(sed -n "${VM_LINE_NUM}p" "$CACHE_FILE")
  VM_NAME=$(echo "$VM_LINE" | cut -d',' -f1)
  VM_IP=$(echo "$VM_LINE" | cut -d',' -f2)
  VM_REGION=$(echo "$VM_LINE" | cut -d',' -f3)
  VM_USER=$(echo "$VM_LINE" | cut -d',' -f4)
  VM_KEY=$(echo "$VM_LINE" | cut -d',' -f5)
}

# 3) Select or type a user
select_user() {
  local users=("${VM_USER} (current)" "ubuntu" "ec2-user" "admin" "Custom...")
  menu_select "SSH user for ${VM_NAME}" "${users[@]}"

  case "$MENU_RESULT" in
    0) ;; # keep current
    1) VM_USER="ubuntu" ;;
    2) VM_USER="ec2-user" ;;
    3) VM_USER="admin" ;;
    4)
      echo ""
      read -rp "  Enter username: " VM_USER
      ;;
  esac
}

# 4) Select an SSH key from ~/.ssh
select_key() {
  local keys=()
  while IFS= read -r f; do
    # Only include files that actually contain a private key
    if head -1 "$f" 2>/dev/null | grep -q "PRIVATE KEY"; then
      keys+=("$f")
    fi
  done < <(find ~/.ssh -maxdepth 1 -type f ! -name "*.pub" ! -name "known_hosts*" ! -name "config" ! -name "authorized_keys" 2>/dev/null | sort)

  if [ ${#keys[@]} -eq 0 ]; then
    echo ""
    printf "  ${YELLOW}No private keys found in ~/.ssh/${RESET}\n"
    read -rp "  Enter full path to key: " VM_KEY
    return
  fi

  local labels=()
  if [ -n "$VM_KEY" ]; then
    labels+=("${VM_KEY} (current)")
  else
    labels+=("(no key)")
  fi
  for k in "${keys[@]}"; do
    labels+=("$k")
  done

  menu_select "SSH key for ${VM_NAME}" "${labels[@]}"

  if [ "$MENU_RESULT" -gt 0 ]; then
    VM_KEY="${keys[$((MENU_RESULT - 1))]}"
  fi
}

# 5) Update cache file with user selections
update_cache() {
  local tmp=$(mktemp)
  local i=1
  while IFS= read -r line; do
    if [ "$i" -eq "$VM_LINE_NUM" ]; then
      echo "${VM_NAME},${VM_IP},${VM_REGION},${VM_USER},${VM_KEY}"
    else
      echo "$line"
    fi
    i=$((i + 1))
  done < "$CACHE_FILE" > "$tmp"
  mv "$tmp" "$CACHE_FILE"
}

# 6) Connect
connect() {
  echo ""
  local cmd="ssh"
  if [ -n "$VM_KEY" ]; then
    cmd="$cmd -i $VM_KEY"
  fi
  cmd="$cmd ${VM_USER}@${VM_IP}"
  printf "  ${GREEN}${BOLD}Connecting:${RESET} %s\n\n" "$cmd"
  eval "$cmd"
}

# --- Main ---

# Cleanup on exit (restore cursor)
trap 'tput cnorm 2>/dev/null' EXIT

if [ "$1" = "refresh" ]; then
  refresh_cache
fi

if [ ! -f "$CACHE_FILE" ] || [ ! -s "$CACHE_FILE" ]; then
  echo "No cache found. Refreshing from AWS..."
  refresh_cache
fi

select_vm
select_user
select_key
update_cache
connect
