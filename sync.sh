#!/bin/bash
# Sync script for NVSD_ItemView
# Copies all project files from WSL dev folder to Windows REAPER scripts folder

SOURCE_DIR="$HOME/dev/NVSD_ItemView"
DEST_DIR="/mnt/d/production/# BOUGHT & FREE soft/Reaper/NVSD_ItemView"

# Sync all files except the sync script itself
rsync -av --exclude='sync.sh' "$SOURCE_DIR/" "$DEST_DIR/"

echo "Synced to: $DEST_DIR"
