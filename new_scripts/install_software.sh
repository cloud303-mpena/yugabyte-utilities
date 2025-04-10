#!/bin/bash

# YugabyteDB System Configuration Script for Amazon Linux
# This script follows the original instructions exactly, assuming YugabyteDB is already installed

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo privileges"
   exit 1
fi

echo "Starting YugabyteDB system configuration..."

# 1. Set up time synchronization
echo "Setting up time synchronization..."

# Install chrony
echo "Installing chrony..."
sudo yum install -y chrony
systemctl enable chronyd
systemctl start chronyd

# Configure PTP using the provided script
echo "Configuring PTP using YugabyteDB script..."
sudo bash ./yugabyte-2024.2.2.2/bin/configure_ptp.sh

# Configure ClockBound using the provided script
echo "Configuring ClockBound using YugabyteDB script..."
sudo bash ./yugabyte-2024.2.2.2/bin/configure_clockbound.sh

# 2. Set ulimits
echo "Setting ulimits..."

# Configure ulimits in /etc/security/limits.conf
cat > /etc/security/limits.conf << EOF
*                -       core            unlimited
*                -       data            unlimited
*                -       fsize           unlimited
*                -       sigpending      119934
*                -       memlock         64
*                -       rss             unlimited
*                -       nofile          1048576
*                -       msgqueue        819200
*                -       stack           8192
*                -       cpu             unlimited
*                -       nproc           12000
*                -       locks           unlimited
EOF

# Configure nproc in /etc/security/limits.d/20-nproc.conf
cat > /etc/security/limits.d/20-nproc.conf << EOF
*          soft    nproc     12000
EOF

# 3. Configure kernel settings
echo "Configuring kernel settings..."

# Configure vm.swappiness
sudo bash -c 'sysctl vm.swappiness=0 >> /etc/sysctl.conf'

# Setup path for core files
sudo sysctl kernel.core_pattern=/home/yugabyte/cores/core_%p_%t_%E

# Configure vm.max_map_count
sudo sysctl -w vm.max_map_count=262144
sudo bash -c 'sysctl vm.max_map_count=262144 >> /etc/sysctl.conf'

# Validate the change
sysctl vm.max_map_count

# 4. Enable transparent hugepages
echo "Configuring transparent hugepages..."

# Check current settings
echo "Current transparent hugepage settings:"
cat /sys/kernel/mm/transparent_hugepage/enabled
cat /sys/kernel/mm/transparent_hugepage/defrag

# Update GRUB configuration
if ! grep -q "transparent_hugepage=always" /etc/default/grub; then
    # Make a backup of the original file
    cp /etc/default/grub /etc/default/grub.bak
    
    # Get current GRUB_CMDLINE_LINUX value
    GRUB_CMDLINE=$(grep "GRUB_CMDLINE_LINUX=" /etc/default/grub | cut -d'"' -f2)
    
    # Add transparent_hugepage=always to GRUB_CMDLINE_LINUX
    NEW_GRUB_CMDLINE="$GRUB_CMDLINE transparent_hugepage=always"
    sed -i "s/GRUB_CMDLINE_LINUX=\".*\"/GRUB_CMDLINE_LINUX=\"$NEW_GRUB_CMDLINE\"/" /etc/default/grub
    
    echo "Updating GRUB configuration..."
    # Make backup of existing grub.cfg
    if [ -f /boot/grub2/grub.cfg ]; then
        cp /boot/grub2/grub.cfg /boot/grub2/grub.cfg.backup
        # Rebuild grub.cfg (BIOS-based machines)
        grub2-mkconfig -o /boot/grub2/grub.cfg
    elif [ -f /boot/efi/EFI/amzn/grub.cfg ]; then
        cp /boot/efi/EFI/amzn/grub.cfg /boot/efi/EFI/amzn/grub.cfg.backup
        # Rebuild grub.cfg (UEFI-based machines)
        grub2-mkconfig -o /boot/efi/EFI/amzn/grub.cfg
    fi
    
    echo "GRUB configuration updated. Transparent hugepages will be enabled after reboot."
else
    echo "Transparent hugepage setting already exists in GRUB configuration."
fi

echo "System configuration complete!"
echo ""
echo "*** IMPORTANT: You need to restart the YB-Master and YB-TServer services for ulimit changes to take effect ***"
echo "*** A system reboot is required for transparent hugepage settings to take effect ***"
echo ""
echo "After restart, verify the transparent hugepages settings with:"
echo "cat /sys/kernel/mm/transparent_hugepage/enabled"
echo "cat /sys/kernel/mm/transparent_hugepage/defrag"
echo "cat /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none"
echo ""
echo "Verify ulimit settings with: ulimit -a"