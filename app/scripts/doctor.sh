#!/bin/bash

echo "Checking Flutter Toolchain..."

# Check Flutter version
FLUTTER_VERSION=$(flutter --version | head -n 1 | awk '{print $2}')
echo "Flutter: $FLUTTER_VERSION"

# Check Xcode version
if command -v xcodebuild &> /dev/null; then
    XCODE_VERSION=$(xcodebuild -version | head -n 1 | awk '{print $2}')
    echo "Xcode: $XCODE_VERSION"
else
    echo "Xcode: Not installed"
fi

# Check CocoaPods version
if command -v pod &> /dev/null; then
    POD_VERSION=$(pod --version)
    echo "CocoaPods: $POD_VERSION"
else
    echo "CocoaPods: Not installed"
fi

echo "---"
echo "Please ensure versions meet the minimums listed in TOOLCHAIN.md."
echo "Flutter >= 3.22.0 | Xcode >= 15.0 | CocoaPods >= 1.15.0"
