#!/usr/bin/env bash
# Copyright (C) 2026 Jaroslav Reznik
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

set -e

# Package ID matching metadata.json
PKG_NAME="org.kde.plasma.geminiusage"
OUT_FILE="${PKG_NAME}.plasmoid"

echo "=================================================================="
echo " 📦 PACKAGING GEMINI USAGE MONITOR PLASMOID"
echo "=================================================================="

# Check for zip
if ! command -v zip &> /dev/null; then
    echo "Error: 'zip' utility is not installed. Please install it." >&2
    exit 1
fi

# Clean previous build
if [ -f "$OUT_FILE" ]; then
    echo "Removing existing package: $OUT_FILE"
    rm -f "$OUT_FILE"
fi

echo "Archiving files into $OUT_FILE..."
# Create the standard zip archive, excluding development and session files
zip -r "$OUT_FILE" . \
    -x "*.git*" \
    -x "*node_modules*" \
    -x "*package.sh*" \
    -x "*.antigravitycli*" \
    -x "*.github*" \
    -x "*.idea*" \
    -x "*.vscode*" \
    -x "*cache.json" \
    -x "*config.json" \
    -x "*.plasmoid"

echo ""
echo "=================================================================="
echo " ✅ SUCCESS: Package created at $OUT_FILE"
echo "=================================================================="
echo "Verify file integrity:"
zipinfo "$OUT_FILE"
echo "=================================================================="
