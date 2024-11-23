#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit
fi

# Function to scan and select a USB device
select_usb_device() {
  echo "Scanning for USB pen drives..."
  USB_DEVICES=$(lsblk -o NAME,TRAN,SIZE,MODEL | grep usb)

  if [ -z "$USB_DEVICES" ]; then
    echo "No USB pen drives detected. Please connect a pen drive and try again."
    exit 1
  fi

  echo "Detected USB devices:"
  echo "$USB_DEVICES"
  echo

  USB_LIST=($(echo "$USB_DEVICES" | awk '{print $1}'))

  if [ ${#USB_LIST[@]} -gt 1 ]; then
    echo "Multiple USB devices detected. Please select one:"
    for i in "${!USB_LIST[@]}"; do
      echo "$((i + 1))) ${USB_LIST[$i]}"
    done

    while true; do
      read -rp "Enter the number corresponding to the USB device: " CHOICE
      if [[ $CHOICE =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#USB_LIST[@]}" ]; then
        SELECTED_DEVICE=${USB_LIST[$((CHOICE - 1))]}
        break
      else
        echo "Invalid choice. Please try again."
      fi
    done
  else
    SELECTED_DEVICE=${USB_LIST[0]}
    echo "Single USB device detected: $SELECTED_DEVICE"
  fi

  echo "/dev/$SELECTED_DEVICE"
}

# Function to create a timestamped backup of a file if changes are needed
backup_file_if_needed() {
  local file=$1
  local temp_file=$(mktemp)

  # Compare current file with a simulated "modified" version
  cat "$file" > "$temp_file"
  if diff -q "$file" "$temp_file" &>/dev/null; then
    rm -f "$temp_file" # Clean up if no changes
  else
    local timestamp=$(date +%Y%m%d%S)
    local backup="$file.$timestamp"
    cp "$file" "$backup"
    echo "Backup of $file created as $backup"
    rm -f "$temp_file" # Clean up temp file
  fi
}

# Parameters
SYSCTL_FILE="/etc/sysctl.conf"

# Get USB device from CLI argument or scan for it
if [ -n "$1" ]; then
  USB_DEVICE="/dev/$1"
  if ! lsblk | grep -q "^$(basename "$USB_DEVICE")"; then
    echo "Invalid device specified: $USB_DEVICE"
    exit 1
  fi
else
  USB_DEVICE=$(select_usb_device)
fi

echo "Using USB device: $USB_DEVICE"
echo

# Start optimizations
echo "Starting USB optimization..."

# 1. Reminder about filesystem choice
echo "Reminder: Ensure your USB device ($USB_DEVICE) is formatted with ext4 for best performance."
echo "If it is not formatted yet, use: sudo mkfs.ext4 $USB_DEVICE"

# 2. Analyze /etc/fstab for the USB device
echo "Examining /etc/fstab for existing entries..."
EXISTING_FSTAB=$(grep "^$USB_DEVICE" /etc/fstab)

if [ -z "$EXISTING_FSTAB" ]; then
  echo "No existing /etc/fstab entry found for $USB_DEVICE."
  echo "Suggested entry for optimal performance:"
  echo "$USB_DEVICE /mnt/usb ext4 defaults,noatime,data=writeback 0 2"
else
  echo "Existing /etc/fstab entry for $USB_DEVICE:"
  echo "$EXISTING_FSTAB"

  # Check for missing optimizations
  if ! echo "$EXISTING_FSTAB" | grep -q "noatime"; then
    echo "Missing 'noatime' option. Suggested update:"
    UPDATED_FSTAB=$(echo "$EXISTING_FSTAB" | sed 's/defaults/defaults,noatime/')
    echo "$UPDATED_FSTAB"
  fi

  if ! echo "$EXISTING_FSTAB" | grep -q "data=writeback"; then
    echo "Missing 'data=writeback' option. Suggested update:"
    UPDATED_FSTAB=$(echo "$EXISTING_FSTAB" | sed 's/defaults/defaults,data=writeback/')
    echo "$UPDATED_FSTAB"
  fi
fi

# 3. Apply sysctl optimizations
echo "Applying sysctl optimizations..."
declare -A SYSCTL_SETTINGS=(
  ["vm.dirty_writeback_centisecs"]="1500"
  ["vm.dirty_ratio"]="40"
  ["vm.dirty_background_ratio"]="10"
  ["vm.swappiness"]="10"
)

# Check if changes are needed and back up the sysctl.conf file
changes_needed=false
for SETTING in "${!SYSCTL_SETTINGS[@]}"; do
  VALUE="${SYSCTL_SETTINGS[$SETTING]}"
  if ! grep -q "^$SETTING = $VALUE" "$SYSCTL_FILE"; then
    changes_needed=true
    break
  fi
done

if $changes_needed; then
  backup_file_if_needed "$SYSCTL_FILE"
fi

# Apply changes to sysctl.conf
for SETTING in "${!SYSCTL_SETTINGS[@]}"; do
  VALUE="${SYSCTL_SETTINGS[$SETTING]}"
  if grep -q "^$SETTING" "$SYSCTL_FILE"; then
    sed -i "s/^$SETTING.*/$SETTING = $VALUE/" "$SYSCTL_FILE"
  else
    echo "$SETTING = $VALUE" >> "$SYSCTL_FILE"
  fi
  sysctl -w "$SETTING=$VALUE"
done

# 4. Check and set readahead size for the USB device
echo "Checking current readahead size for $USB_DEVICE..."
CURRENT_READAHEAD=$(blockdev --getra "$USB_DEVICE")
DESIRED_READAHEAD=2048
if [ "$CURRENT_READAHEAD" -lt "$DESIRED_READAHEAD" ]; then
  echo "Updating readahead size from $CURRENT_READAHEAD to $DESIRED_READAHEAD..."
  blockdev --setra "$DESIRED_READAHEAD" "$USB_DEVICE"
else
  echo "Readahead size ($CURRENT_READAHEAD) is already greater than or equal to $DESIRED_READAHEAD. No changes needed."
fi

# 5. Set IO scheduler for the USB device
echo "Configuring IO scheduler..."
CURRENT_SCHEDULER=$(cat /sys/block/$(basename "$USB_DEVICE")/queue/scheduler | grep -o '\[.*\]' | tr -d '[]')
if [ "$CURRENT_SCHEDULER" != "deadline" ]; then
  echo "Changing IO scheduler to 'deadline'..."
  echo "deadline" > /sys/block/$(basename "$USB_DEVICE")/queue/scheduler
else
  echo "IO scheduler is already set to 'deadline'. No changes needed."
fi

# 6. Enable write caching
echo "Enabling write caching for $USB_DEVICE..."
hdparm -W1 "$USB_DEVICE"

# 7. Disable USB autosuspend
echo "Disabling USB autosuspend..."
USB_BUS=$(lsblk -o NAME,TRAN | grep usb | awk '{print $1}')
for bus in $USB_BUS; do
  echo -1 > "/sys/bus/usb/devices/$bus/power/autosuspend"
done

# 8. Benchmark (echo instead of execution)
echo "Suggested command to benchmark write speed (1GB test file):"
echo "dd if=/dev/zero of=/mnt/usb/testfile bs=1M count=1024 oflag=direct"

echo "All optimizations applied. Review the suggested /etc/fstab updates if necessary!"
