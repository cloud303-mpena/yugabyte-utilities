#!/bin/bash

# YugabyteDB System Configuration Script for Amazon Linux
# This script configures system settings recommended for YugabyteDB on Amazon Linux

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root or with sudo privileges"
   exit 1
fi

echo "Starting YugabyteDB system configuration..."

# Create directories
echo "Creating directories..."
mkdir -p /home/yugabyte/cores
chown -R ec2-user:ec2-user /home/yugabyte 2>/dev/null || true

# Install chrony
echo "Installing chrony for time synchronization..."
yum install -y chrony
systemctl enable chronyd
systemctl start chronyd

# Configure PTP if AWS instance supports it
echo "Checking for PTP support..."
if lspci | grep -q "Elastic Network Adapter"; then
    echo "Configuring PTP (Precision Time Protocol)..."
    # Install required packages
    yum install -y linuxptp ethtool

    # Get the primary interface
    PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}')
    
    # Configure PTP
    cat > /etc/sysconfig/ptp4l << EOF
OPTIONS="-f /etc/ptp4l.conf -i $PRIMARY_INTERFACE --logSelectBestMaster --summary_interval -4 -m"
EOF

    cat > /etc/ptp4l.conf << EOF
[global]
clockClass               248
clockAccuracy            0xFE
offsetScaledLogVariance  0xFFFF
free_running             0
twoStepFlag              1
slaveOnly               1
priority1                128
priority2                128
domainNumber             0
#utc_offset              37
hybrid_e2e               0
tx_timestamp_timeout      10
EOF

    # Configure phc2sys
    cat > /etc/sysconfig/phc2sys << EOF
OPTIONS="-a -r -m -n 24 -z /var/run/ptp4l -t 1 -R 32"
EOF

    # Enable and start PTP services
    systemctl enable ptp4l
    systemctl start ptp4l
    systemctl enable phc2sys
    systemctl start phc2sys
    
    echo "PTP configuration complete"
else
    echo "This instance does not appear to support PTP. Skipping PTP configuration."
fi

# Install and configure ClockBound
echo "Installing and configuring ClockBound..."
# Check if clockbound is already installed
if ! command -v clockbound &> /dev/null; then
    # Install dependencies
    yum install -y git gcc gcc-c++ make

    # Install Rust if not already installed
    if ! command -v cargo &> /dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi

    # Clone and build clockbound
    cd /tmp
    git clone https://github.com/facebook/time.git
    cd time/clockbound
    cargo build --release
    cp target/release/clockbound /usr/local/bin/

    # Create systemd service file
    cat > /usr/lib/systemd/system/clockbound.service << EOF
[Unit]
Description=ClockBound
After=network.target chronyd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/clockbound --max-drift-rate 50
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # If PTP is configured, update the service
    if systemctl is-active ptp4l > /dev/null 2>&1; then
        PHC_DEV="PHC0"
        INTERFACE="$PRIMARY_INTERFACE"
        sed -i "s|ExecStart=.*|ExecStart=/usr/local/bin/clockbound --max-drift-rate 50 -r $PHC_DEV -i $INTERFACE|" /usr/lib/systemd/system/clockbound.service
    fi

    # Enable and start ClockBound
    systemctl enable clockbound
    systemctl start clockbound
    
    echo "ClockBound installation and configuration complete"
else
    echo "ClockBound appears to be already installed. Skipping installation."
fi

# Set ulimits in /etc/security/limits.conf
echo "Configuring ulimits..."
cat > /etc/security/limits.conf << EOF
# /etc/security/limits.conf
# YugabyteDB recommended settings
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

# Create or update the nproc limits file
cat > /etc/security/limits.d/20-nproc.conf << EOF
# Default limit for number of user's processes to prevent accidental fork bombs
*          soft    nproc     12000
root       soft    nproc     unlimited
EOF

# Configure kernel settings
echo "Configuring kernel settings..."
# Swappiness
sysctl -w vm.swappiness=0
grep -q "vm.swappiness" /etc/sysctl.conf && sed -i "s/vm.swappiness=.*/vm.swappiness=0/" /etc/sysctl.conf || echo "vm.swappiness=0" >> /etc/sysctl.conf

# Core pattern
sysctl -w kernel.core_pattern=/home/yugabyte/cores/core_%p_%t_%E
grep -q "kernel.core_pattern" /etc/sysctl.conf && sed -i "s|kernel.core_pattern=.*|kernel.core_pattern=/home/yugabyte/cores/core_%p_%t_%E|" /etc/sysctl.conf || echo "kernel.core_pattern=/home/yugabyte/cores/core_%p_%t_%E" >> /etc/sysctl.conf

# Max map count
sysctl -w vm.max_map_count=262144
grep -q "vm.max_map_count" /etc/sysctl.conf && sed -i "s/vm.max_map_count=.*/vm.max_map_count=262144/" /etc/sysctl.conf || echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# Enable transparent hugepages
echo "Configuring transparent hugepages..."
# Check current settings
echo "Current transparent hugepage settings:"
cat /sys/kernel/mm/transparent_hugepage/enabled
cat /sys/kernel/mm/transparent_hugepage/defrag

# Update GRUB configuration if needed
if ! grep -q "transparent_hugepage=always" /etc/default/grub; then
    GRUB_CMDLINE=$(grep "GRUB_CMDLINE_LINUX=" /etc/default/grub | cut -d'"' -f2)
    NEW_GRUB_CMDLINE="$GRUB_CMDLINE transparent_hugepage=always"
    sed -i "s/GRUB_CMDLINE_LINUX=\".*\"/GRUB_CMDLINE_LINUX=\"$NEW_GRUB_CMDLINE\"/" /etc/default/grub
    
    echo "Updating GRUB configuration..."
    # For Amazon Linux 2, use grub2-mkconfig to update the GRUB configuration
    if [ -f /boot/grub2/grub.cfg ]; then
        cp /boot/grub2/grub.cfg /boot/grub2/grub.cfg.backup
        grub2-mkconfig -o /boot/grub2/grub.cfg
    elif [ -f /boot/efi/EFI/amzn/grub.cfg ]; then
        cp /boot/efi/EFI/amzn/grub.cfg /boot/efi/EFI/amzn/grub.cfg.backup
        grub2-mkconfig -o /boot/efi/EFI/amzn/grub.cfg
    fi
    
    echo "GRUB configuration updated. Transparent hugepages will be enabled after reboot."
else
    echo "Transparent hugepage setting already exists in GRUB configuration."
fi

# Set it immediately if possible (may not work on all systems)
echo always > /sys/kernel/mm/transparent_hugepage/enabled
echo "defer+madvise" > /sys/kernel/mm/transparent_hugepage/defrag
echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none

# Create systemd service templates for YugabyteDB
echo "Creating systemd service templates for YugabyteDB..."

# YB-Master service template
cat > /etc/systemd/system/yb-master.service << EOF
[Unit]
Description=YugabyteDB Master Server
After=network.target

[Service]
User=yugabyte
Group=yugabyte
ExecStart=/home/yugabyte/yugabyte/bin/yb-master --flagfile=/home/yugabyte/yugabyte/conf/master.conf
Restart=always
RestartSec=10
LimitCPU=infinity
LimitFSIZE=infinity
LimitDATA=infinity
LimitSTACK=8388608
LimitCORE=infinity
LimitRSS=infinity
LimitNOFILE=1048576
LimitAS=infinity
LimitNPROC=12000
LimitMEMLOCK=64
LimitLOCKS=infinity
LimitSIGPENDING=119934
LimitMSGQUEUE=819200
LimitNICE=0
LimitRTPRIO=0

[Install]
WantedBy=multi-user.target
EOF

# YB-TServer service template
cat > /etc/systemd/system/yb-tserver.service << EOF
[Unit]
Description=YugabyteDB TServer
After=network.target

[Service]
User=yugabyte
Group=yugabyte
ExecStart=/home/yugabyte/yugabyte/bin/yb-tserver --flagfile=/home/yugabyte/yugabyte/conf/tserver.conf
Restart=always
RestartSec=10
LimitCPU=infinity
LimitFSIZE=infinity
LimitDATA=infinity
LimitSTACK=8388608
LimitCORE=infinity
LimitRSS=infinity
LimitNOFILE=1048576
LimitAS=infinity
LimitNPROC=12000
LimitMEMLOCK=64
LimitLOCKS=infinity
LimitSIGPENDING=119934
LimitMSGQUEUE=819200
LimitNICE=0
LimitRTPRIO=0

[Install]
WantedBy=multi-user.target
EOF

echo "SystemD service templates created. You'll need to update the configuration flags as needed."

# Reload systemd
systemctl daemon-reload

echo "System configuration complete!"
echo ""
echo "*** IMPORTANT: Some changes require a system restart to take effect ***"
echo "To apply all settings, please restart your system with: sudo reboot"
echo ""
echo "After restart, verify the transparent hugepages settings with:"
echo "cat /sys/kernel/mm/transparent_hugepage/enabled"
echo "cat /sys/kernel/mm/transparent_hugepage/defrag"
echo ""
echo "Verify ulimit settings with: ulimit -a"
echo ""
echo "If using ClockBound, verify it's running with: systemctl status clockbound"