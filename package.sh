#!/bin/bash
# Package script for Gumroad distribution
# Creates a ZIP file ready for upload

VERSION="1.0.0"
PACKAGE_NAME="NVSD_ItemView_v${VERSION}"

# Clean and create temp directory
rm -rf "./dist"
mkdir -p "./dist/${PACKAGE_NAME}/lib"

# Copy main scripts
cp "NVSD_ItemView.lua" "./dist/${PACKAGE_NAME}/"
cp "NVSD_ItemView_Settings.lua" "./dist/${PACKAGE_NAME}/"

# Copy lib modules
cp lib/config.lua "./dist/${PACKAGE_NAME}/lib/"
cp lib/state.lua "./dist/${PACKAGE_NAME}/lib/"
cp lib/utils.lua "./dist/${PACKAGE_NAME}/lib/"
cp lib/drawing.lua "./dist/${PACKAGE_NAME}/lib/"
cp lib/controls.lua "./dist/${PACKAGE_NAME}/lib/"
cp lib/settings.lua "./dist/${PACKAGE_NAME}/lib/"
cp lib/settings_ui.lua "./dist/${PACKAGE_NAME}/lib/"

# Copy documentation
cp "INSTALL.txt" "./dist/${PACKAGE_NAME}/"
cp "README.md" "./dist/${PACKAGE_NAME}/"
cp "LICENSE.txt" "./dist/${PACKAGE_NAME}/"

# Create ZIP
cd "./dist"
zip -r "${PACKAGE_NAME}.zip" "${PACKAGE_NAME}"
cd ..

echo ""
echo "Package created: dist/${PACKAGE_NAME}.zip"
echo ""
echo "Contents:"
unzip -l "./dist/${PACKAGE_NAME}.zip"
echo ""
echo "Ready to upload to Gumroad!"
