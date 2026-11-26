#!/bin/bash
# Build Desk Quote.app and install it in ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/DeskQuote.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/DeskQuote" Sources/main.swift
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"

pkill -x DeskQuote || true
mkdir -p ~/Applications
rm -rf ~/Applications/DeskQuote.app
cp -R "$APP" ~/Applications/
open ~/Applications/DeskQuote.app
echo "Installed ~/Applications/DeskQuote.app"
