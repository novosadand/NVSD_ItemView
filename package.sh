#!/bin/bash
# Package script for Gumroad distribution
# Creates a ZIP file ready for upload

VERSION="1.0"
PACKAGE_NAME="NVSD_ItemView_v${VERSION}"

# Create temp directory
rm -rf "./dist"
mkdir -p "./dist/${PACKAGE_NAME}"

# Copy distribution files
cp "NVSD_ItemView.lua" "./dist/${PACKAGE_NAME}/"
cp "INSTALL.txt" "./dist/${PACKAGE_NAME}/"
cp "README.md" "./dist/${PACKAGE_NAME}/"

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
