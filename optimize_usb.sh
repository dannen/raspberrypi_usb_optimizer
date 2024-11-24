#!/usr/bin/env bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit
fi

# Function to scan and select a USB device
select_usb_device() {
  USB_DEVICES=$(lsblk -o NAME,TRAN,SIZE,MODEL | grep usb | awk '{print $1}')

  if [ -z "$USB_DEVICES" ]; then
    echo "No USB pen drives detected. Please connect a pen drive and try again."
    exit 1
  fi

  echo "Detected USB devices:"
  lsblk -o NAME,TRAN,SIZE,MODEL | grep usb
  echo

  USB_LIST=($USB_DEVICES)

  if [ ${#USB_LIST[@]} -gt 1 ]; then
    echo "Multiple USB devices detected. Please select one:"
    for i in "${!USB_LIST[@]}"; do
      echo "$((i + 1))) /dev/${USB_LIST[$i]}"
    done
    while true; do
      read -rp "Enter the number corresponding to the USB device: " CHOICE
      if [[ $CHOICE =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#USB_LIST[@]}" ]; then
        SELECTED_DEVICE="/dev/${USB_LIST[$((CHOICE - 1))]}"
        echo "$SELECTED_DEVICE"
        return
      else
        echo "Invalid choice. Please try again."
      fi
    done
  else
    SELECTED_DEVICE="/dev/${USB_LIST[0]}"
    echo "$SELECTED_DEVICE"
    return
  fi
}

# Function to create a timestamped backup of a file if changes are needed
backup_file_if_needed() {
  local file=$1
  if [ -f "$file" ]; then
    local timestamp=$(date +%Y%m%d%H%M%S)
    local backup="$file.$timestamp"
    cp "$file" "$backup"
    echo "Backup of $file created as $backup"
  fi
}

# Function to set I/O scheduler
set_scheduler() {
  local device=$(basename "$1")
  local scheduler="kyber"
  local sched_file="/sys/block/$device/queue/scheduler"

  if [ ! -f "$sched_file" ]; then
    echo "Scheduler file not found for $device. Skipping scheduler tuning."
    return
  fi

  echo "Current scheduler for $device:"
  cat "$sched_file"

  echo "Setting scheduler to $scheduler..."
  echo "$scheduler" | sudo tee "$sched_file" > /dev/null

  # Verify the change
  local new_scheduler=$(cat "$sched_file" | grep -o '\[.*\]' | tr -d '[]')
  if [ "$new_scheduler" == "$scheduler" ]; then
    echo "Scheduler successfully set to $scheduler for $device."
  else
    echo "Failed to set scheduler to $scheduler. Current scheduler: $new_scheduler"
  fi

  # Persistent configuration via udev rule
  read -rp "Do you want to make $scheduler the default scheduler for $device? (y/n): " PERSIST_CONFIRM
  if [[ "$PERSIST_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Creating udev rule for persistent scheduler configuration..."
    local udev_file="/etc/udev/rules.d/60-scheduler.rules"
    backup_file_if_needed "$udev_file"
    echo "ACTION==\"add|change\", KERNEL==\"$device\", ATTR{queue/scheduler}=\"$scheduler\"" | sudo tee "$udev_file"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    echo "Persistent scheduler configuration added for $device."
  fi
}

# Parameters
MOUNT_POINT="/mnt/usb"

# Get USB device from CLI argument or scan for it
if [ -n "$1" ]; then
  USB_DEVICE="/dev/$1"
  if ! lsblk | grep -q "^$(basename "$USB_DEVICE")"; then
    echo "Invalid device specified: $USB_DEVICE"
    exit 1
  fi
else
  USB_DEVICE=$(select_usb_device | tail -n 1)
fi

echo "Using USB device: $USB_DEVICE"

# Test and set I/O scheduler
set_scheduler "$USB_DEVICE"

# Mount the drive with optimized options
echo "Creating mount point at $MOUNT_POINT..."
sudo mkdir -p "$MOUNT_POINT"
echo "Mounting $USB_DEVICE with noatime and data=writeback..."
sudo mount -o defaults,noatime,data=writeback "$USB_DEVICE" "$MOUNT_POINT"

# Test mount and persist in /etc/fstab
if mountpoint -q "$MOUNT_POINT"; then
  echo "$USB_DEVICE successfully mounted at $MOUNT_POINT."
  read -rp "Do you want to add this mount to /etc/fstab for persistence? (y/n): " FSTAB_CONFIRM
  if [[ "$FSTAB_CONFIRM" =~ ^[Yy]$ ]]; then
    FSTAB_ENTRY="$USB_DEVICE $MOUNT_POINT ext4 defaults,noatime,data=writeback 0 2"
    if ! grep -q "$USB_DEVICE" /etc/fstab; then
      backup_file_if_needed "/etc/fstab"
      echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
      echo "Entry added to /etc/fstab."
    else
      echo "Entry already exists in /etc/fstab. Skipping."
    fi
  fi
else
  echo "Failed to mount $USB_DEVICE at $MOUNT_POINT."
  exit 1
fi

echo "Suggested command to benchmark write speed:"
echo "dd if=/dev/zero of=$MOUNT_POINT/testfile bs=1M count=1024 oflag=direct"
