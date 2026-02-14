#!/bin/bash
# Clone an existing EC2 instance by generating a creation script
# Usage: ./clone-ec2.sh [refresh]

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

# --- Colors and symbols ---
BOLD="\033[1m"
DIM="\033[2m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"
ARROW="▸"

# --- Arrow-key menu selector ---
# Returns selected index via global MENU_RESULT
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

  while true; do
    read -rsn1 key
    case "$key" in
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

# Refresh cache from AWS
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
  tput el 2>/dev/null
  printf "  ${GREEN}Cache updated${RESET} (%s instances)\n" "$(wc -l < "$CACHE_FILE" | tr -d ' ')"
}

# Select a VM from cache
select_vm() {
  if [ ! -f "$CACHE_FILE" ] || [ ! -s "$CACHE_FILE" ]; then
    echo "Cache is empty. Run with 'refresh' first."
    exit 1
  fi

  local labels=()
  while IFS=',' read -r name ip region user key; do
    labels+=("$(printf "%-20s %-16s %-14s %s" "$name" "$ip" "$region" "$user")")
  done < "$CACHE_FILE"

  menu_select "Select the EC2 instance to clone (↑↓ arrows, Enter to confirm)" "${labels[@]}"

  VM_LINE_NUM=$((MENU_RESULT + 1))
  VM_LINE=$(sed -n "${VM_LINE_NUM}p" "$CACHE_FILE")
  VM_NAME=$(echo "$VM_LINE" | cut -d',' -f1)
  VM_IP=$(echo "$VM_LINE" | cut -d',' -f2)
  VM_REGION=$(echo "$VM_LINE" | cut -d',' -f3)
}

# Ask for the new instance name
ask_new_name() {
  echo ""
  local default_name="${VM_NAME}-clone"
  read -rp "  Name for the new instance [${default_name}]: " NEW_NAME
  NEW_NAME=${NEW_NAME:-${default_name}}
}

# Fetch full instance details and generate script
generate_clone_script() {
  echo ""
  printf "  ${CYAN}Reading instance details for ${VM_NAME}...${RESET}\n"

  # Get the instance ID from name and region
  INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$VM_REGION" \
    --filters "Name=tag:Name,Values=${VM_NAME}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null)

  if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
    printf "  ${YELLOW}Could not find instance ID for ${VM_NAME}${RESET}\n"
    exit 1
  fi

  # Fetch full instance description
  INSTANCE_JSON=$(aws ec2 describe-instances \
    --region "$VM_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0]' \
    --output json 2>/dev/null)

  # Extract all characteristics
  AMI_ID=$(echo "$INSTANCE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['ImageId'])")
  INSTANCE_TYPE=$(echo "$INSTANCE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['InstanceType'])")
  KEY_NAME=$(echo "$INSTANCE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('KeyName',''))")
  SUBNET_ID=$(echo "$INSTANCE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['SubnetId'])")
  VPC_ID=$(echo "$INSTANCE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['VpcId'])")

  # Security groups
  SG_IDS=$(echo "$INSTANCE_JSON" | python3 -c "
import sys, json
sgs = json.load(sys.stdin).get('SecurityGroups', [])
print(' '.join(sg['GroupId'] for sg in sgs))
")

  # Block device mappings (disk config)
  BLOCK_DEVICES=$(echo "$INSTANCE_JSON" | python3 -c "
import sys, json
inst = json.load(sys.stdin)
bdms = inst.get('BlockDeviceMappings', [])
result = []
for bdm in bdms:
    dev = bdm['DeviceName']
    vol_id = bdm.get('Ebs', {}).get('VolumeId', '')
    if vol_id:
        result.append({'dev': dev, 'vol_id': vol_id})
print(json.dumps(result))
")

  # Get volume details for each disk
  BLOCK_DEVICE_SPEC=$(echo "$BLOCK_DEVICES" | python3 -c "
import sys, json, subprocess
bdms = json.load(sys.stdin)
specs = []
for bdm in bdms:
    vol = subprocess.run(
        ['aws', 'ec2', 'describe-volumes', '--volume-ids', bdm['vol_id'],
         '--region', '${VM_REGION}', '--output', 'json'],
        capture_output=True, text=True
    )
    if vol.returncode == 0:
        v = json.loads(vol.stdout)['Volumes'][0]
        spec = {
            'DeviceName': bdm['dev'],
            'Ebs': {
                'VolumeSize': v['Size'],
                'VolumeType': v['VolumeType'],
                'DeleteOnTermination': True
            }
        }
        if v['VolumeType'] in ('io1', 'io2', 'gp3') and v.get('Iops'):
            spec['Ebs']['Iops'] = v['Iops']
        if v['VolumeType'] == 'gp3' and v.get('Throughput'):
            spec['Ebs']['Throughput'] = v['Throughput']
        if v.get('Encrypted'):
            spec['Ebs']['Encrypted'] = True
            if v.get('KmsKeyId'):
                spec['Ebs']['KmsKeyId'] = v['KmsKeyId']
        specs.append(spec)
print(json.dumps(specs))
")

  # IAM instance profile
  IAM_PROFILE=$(echo "$INSTANCE_JSON" | python3 -c "
import sys, json
inst = json.load(sys.stdin)
profile = inst.get('IamInstanceProfile', {})
arn = profile.get('Arn', '')
if arn:
    # Extract profile name from ARN
    print(arn.split('/')[-1])
" 2>/dev/null)

  # Public IP association (check if in a public subnet)
  HAS_PUBLIC_IP=$(echo "$INSTANCE_JSON" | python3 -c "
import sys, json
inst = json.load(sys.stdin)
print('true' if inst.get('PublicIpAddress') else 'false')
")

  # Tags (excluding Name which we'll set separately)
  EXTRA_TAGS=$(echo "$INSTANCE_JSON" | python3 -c "
import sys, json
inst = json.load(sys.stdin)
tags = inst.get('Tags', [])
extra = [t for t in tags if t['Key'] != 'Name' and not t['Key'].startswith('aws:')]
if extra:
    parts = ','.join('{Key=%s,Value=%s}' % (t['Key'], t['Value']) for t in extra)
    print(parts)
" 2>/dev/null)

  # User data
  USER_DATA=$(aws ec2 describe-instance-attribute \
    --region "$VM_REGION" \
    --instance-id "$INSTANCE_ID" \
    --attribute userData \
    --query 'UserData.Value' \
    --output text 2>/dev/null)

  # Get AMI name for reference
  AMI_NAME=$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$VM_REGION" \
    --query 'Images[0].Name' --output text 2>/dev/null)

  # --- Generate the script ---
  local safe_name=$(echo "$NEW_NAME" | tr ' ' '-')
  OUTPUT_FILE="./create-ec2-${safe_name}.sh"

  cat > "$OUTPUT_FILE" << 'HEADER'
#!/bin/bash
# Auto-generated script to create an EC2 instance
# Cloned from: SOURCE_NAME (SOURCE_ID)
# Generated on: GENERATED_DATE

REGION="SOURCE_REGION"
INSTANCE_NAME="NEW_INSTANCE_NAME"

HEADER

  # Replace placeholders
  sed -i '' "s/SOURCE_NAME/${VM_NAME}/g" "$OUTPUT_FILE"
  sed -i '' "s/SOURCE_ID/${INSTANCE_ID}/g" "$OUTPUT_FILE"
  sed -i '' "s/GENERATED_DATE/$(date '+%Y-%m-%d %H:%M:%S')/g" "$OUTPUT_FILE"
  sed -i '' "s/SOURCE_REGION/${VM_REGION}/g" "$OUTPUT_FILE"
  sed -i '' "s/NEW_INSTANCE_NAME/${NEW_NAME}/g" "$OUTPUT_FILE"

  cat >> "$OUTPUT_FILE" << EOF
# Check AWS session
if ! aws sts get-caller-identity &>/dev/null; then
  echo "AWS session expired. Initiating login..."
  aws login || exit 1
fi

echo "Creating EC2 instance: \$INSTANCE_NAME"
echo "  Region:        \$REGION"
echo "  AMI:           ${AMI_ID} (${AMI_NAME})"
echo "  Instance type: ${INSTANCE_TYPE}"
echo "  Subnet:        ${SUBNET_ID}"
echo "  VPC:           ${VPC_ID}"
echo "  Key pair:      ${KEY_NAME}"
echo "  Security groups: ${SG_IDS}"
echo ""
read -rp "Continue? [y/N] " confirm
if [ "\$confirm" != "y" ] && [ "\$confirm" != "Y" ]; then
  echo "Aborted."
  exit 0
fi

INSTANCE_ID=\$(aws ec2 run-instances \\
  --region "\$REGION" \\
  --image-id "${AMI_ID}" \\
  --instance-type "${INSTANCE_TYPE}" \\
EOF

  # Key pair
  if [ -n "$KEY_NAME" ]; then
    echo "  --key-name \"${KEY_NAME}\" \\" >> "$OUTPUT_FILE"
  fi

  # Security groups
  echo "  --security-group-ids ${SG_IDS} \\" >> "$OUTPUT_FILE"

  # Subnet
  echo "  --subnet-id \"${SUBNET_ID}\" \\" >> "$OUTPUT_FILE"

  # Public IP
  if [ "$HAS_PUBLIC_IP" = "true" ]; then
    echo "  --associate-public-ip-address \\" >> "$OUTPUT_FILE"
  fi

  # Block device mappings
  echo "  --block-device-mappings '${BLOCK_DEVICE_SPEC}' \\" >> "$OUTPUT_FILE"

  # IAM profile
  if [ -n "$IAM_PROFILE" ]; then
    echo "  --iam-instance-profile \"Name=${IAM_PROFILE}\" \\" >> "$OUTPUT_FILE"
  fi

  # User data
  if [ -n "$USER_DATA" ] && [ "$USER_DATA" != "None" ]; then
    # Decode and save user data to a file
    USERDATA_FILE="./userdata-${NEW_NAME}.sh"
    echo "$USER_DATA" | base64 -d > "$USERDATA_FILE"
    echo "  --user-data \"file://${USERDATA_FILE}\" \\" >> "$OUTPUT_FILE"
  fi

  # Tags
  TAG_SPEC="{Key=Name,Value=\$INSTANCE_NAME}"
  if [ -n "$EXTRA_TAGS" ]; then
    TAG_SPEC="${TAG_SPEC},${EXTRA_TAGS}"
  fi

  cat >> "$OUTPUT_FILE" << EOF
  --tag-specifications "ResourceType=instance,Tags=[${TAG_SPEC}]" \\
  --query 'Instances[0].InstanceId' --output text)

echo ""
echo "Instance created: \$INSTANCE_ID"

# Wait for running state
echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "\$INSTANCE_ID" --region "\$REGION"

# Get public IP
PUBLIC_IP=\$(aws ec2 describe-instances \\
  --instance-ids "\$INSTANCE_ID" \\
  --region "\$REGION" \\
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo ""
echo "Instance \$INSTANCE_NAME is running!"
echo "  Instance ID: \$INSTANCE_ID"
echo "  Public IP:   \$PUBLIC_IP"
EOF

  # Add SSH connection hint
  if [ -n "$KEY_NAME" ]; then
    SSH_USER=$(guess_user "$AMI_NAME")
    echo "echo \"  Connect:     ssh ${SSH_USER}@\$PUBLIC_IP\"" >> "$OUTPUT_FILE"
  fi

  chmod +x "$OUTPUT_FILE"

  echo ""
  printf "  ${GREEN}${BOLD}Script generated:${RESET} %s\n" "$OUTPUT_FILE"
  echo ""
  printf "  ${DIM}Source instance:${RESET}  %s (%s)\n" "$VM_NAME" "$INSTANCE_ID"
  printf "  ${DIM}AMI:${RESET}             %s (%s)\n" "$AMI_ID" "$AMI_NAME"
  printf "  ${DIM}Instance type:${RESET}   %s\n" "$INSTANCE_TYPE"
  printf "  ${DIM}Subnet:${RESET}          %s\n" "$SUBNET_ID"
  printf "  ${DIM}VPC:${RESET}             %s\n" "$VPC_ID"
  printf "  ${DIM}Key pair:${RESET}        %s\n" "$KEY_NAME"
  printf "  ${DIM}Security groups:${RESET} %s\n" "$SG_IDS"
  printf "  ${DIM}Disks:${RESET}           %s\n" "$BLOCK_DEVICE_SPEC"
  if [ -n "$IAM_PROFILE" ]; then
    printf "  ${DIM}IAM profile:${RESET}   %s\n" "$IAM_PROFILE"
  fi
  if [ -n "$USER_DATA" ] && [ "$USER_DATA" != "None" ]; then
    printf "  ${DIM}User data:${RESET}     %s\n" "$USERDATA_FILE"
  fi
  echo ""
  printf "  Run ${BOLD}./%s${RESET} to create the clone.\n" "$(basename "$OUTPUT_FILE")"
}

# --- Main ---
trap 'tput cnorm 2>/dev/null' EXIT

if [ "$1" = "refresh" ]; then
  refresh_cache
fi

if [ ! -f "$CACHE_FILE" ] || [ ! -s "$CACHE_FILE" ]; then
  echo "No cache found. Refreshing from AWS..."
  refresh_cache
fi

select_vm
ask_new_name
generate_clone_script
