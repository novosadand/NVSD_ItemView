#!/bin/bash
# Sync script for NVSD_ItemView
# Copies project files to your REAPER Scripts folder
#
# CONFIGURATION REQUIRED:
# Edit DEST_DIR below to point to your REAPER Scripts folder
# Examples:
#   Windows (WSL): /mnt/c/Users/YourName/AppData/Roaming/REAPER/Scripts/NVSD_ItemView
#   macOS:         ~/Library/Application Support/REAPER/Scripts/NVSD_ItemView
#   Linux:         ~/.config/REAPER/Scripts/NVSD_ItemView

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR=""  # <-- SET THIS TO YOUR REAPER SCRIPTS FOLDER

if [ -z "$DEST_DIR" ]; then
    echo "ERROR: DEST_DIR not configured."
    echo "Edit sync.sh and set DEST_DIR to your REAPER Scripts folder."
    exit 1
fi

# Create destination if it doesn't exist
mkdir -p "$DEST_DIR"

# Sync all files except dev-only files
rsync -av \
    --exclude='sync.sh' \
    --exclude='tests/' \
    --exclude='.git/' \
    --exclude='DEVELOPMENT.md' \
    "$SOURCE_DIR/" "$DEST_DIR/"

echo "Synced to: $DEST_DIR"
