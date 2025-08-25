#!/usr/bin/env bash
# Configure GRUB timeout and default boot option

echo "=== Configuring GRUB for faster boot ==="

# SSH into the VM and configure GRUB
ssh -o StrictHostKeyChecking=no -p 2230 ubuntu@localhost << 'EOSSH'
# Change default password if first login
echo "ubuntu:newpass123" | sudo chpasswd

# Backup original GRUB config
sudo cp /etc/default/grub /etc/default/grub.bak

# Update GRUB timeout to 3 seconds
sudo sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub

# Set default boot option to first entry
sudo sed -i 's/GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub

# Update GRUB configuration
sudo update-grub

echo "GRUB configuration updated:"
cat /etc/default/grub | grep -E "(GRUB_TIMEOUT|GRUB_DEFAULT)"

echo "Reboot to apply changes: sudo reboot"
EOSSH