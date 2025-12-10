#!/bin/bash

# Build and Sign APK Script
# This script builds the release APK, moves it to the provision directory,
# and signs it with the private key from the signing directory.

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
ANDROID_DIR="$PROJECT_ROOT"
SIGNING_DIR="$PROJECT_ROOT/signing"
PROVISION_DIR="$PROJECT_ROOT"

# Key files
PRIVATE_KEY="$SIGNING_DIR/priv_key.pem"
PUBLIC_KEY="$SIGNING_DIR/rsa_key.pub"
KEYSTORE_FILE="$SIGNING_DIR/app-release.keystore"
KEYSTORE_PASSWORD="sugarpixel-release"
KEY_ALIAS="sugarpixel-release"
KEY_PASSWORD="sugarpixel-release"

# APK files
BUILD_APK="$ANDROID_DIR/app/build/outputs/apk/release/app-release-unsigned.apk"
SIGNED_APK="$PROVISION_DIR/app-release-signed.apk"
FINAL_APK="$PROVISION_DIR/app-release.apk"

echo "=========================================="
echo "Building and Signing APK"
echo "=========================================="

# Step 1: Check if private key exists
if [ ! -f "$PRIVATE_KEY" ]; then
    echo "ERROR: Private key not found at $PRIVATE_KEY"
    exit 1
fi

# Step 2: Create keystore from PEM key if it doesn't exist
if [ ! -f "$KEYSTORE_FILE" ]; then
    echo "Creating keystore from PEM private key..."
    
    # Check if openssl is available
    if ! command -v openssl &> /dev/null; then
        echo "ERROR: openssl is required but not installed"
        exit 1
    fi
    
    # Check if keytool is available
    if ! command -v keytool &> /dev/null; then
        echo "ERROR: keytool (Java JDK) is required but not installed"
        exit 1
    fi
    
    # Create a temporary PKCS12 file from PEM key
    TEMP_P12="$SIGNING_DIR/temp.p12"
    
    # Generate a self-signed certificate from the private key
    echo "Generating certificate from private key..."
    openssl req -new -x509 -key "$PRIVATE_KEY" -out "$SIGNING_DIR/temp.crt" -days 3650 \
        -subj "/CN=SugarPixel Release/O=CustomTypeOne/OU=Mobile/L=Unknown/ST=Unknown/C=US" 2>/dev/null || \
    openssl req -new -x509 -key "$PRIVATE_KEY" -out "$SIGNING_DIR/temp.crt" -days 3650 \
        -subj "/CN=SugarPixel Release" 2>/dev/null
    
    # Convert PEM key + cert to PKCS12
    echo "Converting to PKCS12 format..."
    openssl pkcs12 -export \
        -in "$SIGNING_DIR/temp.crt" \
        -inkey "$PRIVATE_KEY" \
        -out "$TEMP_P12" \
        -name "$KEY_ALIAS" \
        -password "pass:$KEYSTORE_PASSWORD" \
        -noiter -nomaciter
    
    # Convert PKCS12 to JKS keystore
    echo "Creating Java keystore..."
    keytool -importkeystore \
        -srckeystore "$TEMP_P12" \
        -srcstoretype PKCS12 \
        -srcstorepass "$KEYSTORE_PASSWORD" \
        -destkeystore "$KEYSTORE_FILE" \
        -deststoretype JKS \
        -deststorepass "$KEYSTORE_PASSWORD" \
        -destkeypass "$KEY_PASSWORD" \
        -alias "$KEY_ALIAS" \
        -noprompt
    
    # Clean up temporary files
    rm -f "$TEMP_P12" "$SIGNING_DIR/temp.crt"
    
    echo "✓ Keystore created successfully"
else
    echo "✓ Using existing keystore"
fi

# Step 3: Build the release APK
echo ""
echo "Building release APK..."
cd "$ANDROID_DIR"

# Clean only output directories (not CMake cache which can cause issues)
echo "Cleaning build outputs..."
rm -rf app/build/intermediates
rm -rf app/build/outputs
rm -rf build/intermediates
rm -rf build/outputs

# Clean CMake cache if it exists (to avoid autolinking issues)
if [ -d "app/.cxx" ]; then
    echo "Cleaning CMake cache..."
    rm -rf app/.cxx
fi

# Build release APK (skip clean task to avoid CMake autolinking issues)
# The codegen directories will be generated during the build
echo "Building release APK..."
./gradlew assembleRelease --no-daemon -x clean

if [ ! -f "$BUILD_APK" ]; then
    echo "ERROR: APK build failed - file not found at $BUILD_APK"
    exit 1
fi

echo "✓ APK built successfully"

# Step 4: Check if apksigner is available
APKSIGNER_PATH=""
if [ -n "$ANDROID_HOME" ]; then
    APKSIGNER_PATH="$ANDROID_HOME/build-tools/$(ls -1 "$ANDROID_HOME/build-tools" | sort -V | tail -1)/apksigner"
fi

# Try common locations
if [ ! -f "$APKSIGNER_PATH" ]; then
    APKSIGNER_PATH=$(which apksigner 2>/dev/null || echo "")
fi

if [ -z "$APKSIGNER_PATH" ] || [ ! -f "$APKSIGNER_PATH" ]; then
    echo "ERROR: apksigner not found. Please ensure Android SDK build-tools are installed."
    echo "       Set ANDROID_HOME environment variable or add apksigner to PATH."
    exit 1
fi

echo "✓ Found apksigner at $APKSIGNER_PATH"

# Step 5: Sign the APK
echo ""
echo "Signing APK..."
"$APKSIGNER_PATH" sign \
    --ks "$KEYSTORE_FILE" \
    --ks-pass "pass:$KEYSTORE_PASSWORD" \
    --ks-key-alias "$KEY_ALIAS" \
    --key-pass "pass:$KEY_PASSWORD" \
    --out "$SIGNED_APK" \
    "$BUILD_APK"

if [ ! -f "$SIGNED_APK" ]; then
    echo "ERROR: APK signing failed"
    exit 1
fi

echo "✓ APK signed successfully"

# Step 6: Verify the signature
echo ""
echo "Verifying signature..."
"$APKSIGNER_PATH" verify "$SIGNED_APK"

if [ $? -eq 0 ]; then
    echo "✓ Signature verified successfully"
else
    echo "ERROR: Signature verification failed"
    exit 1
fi

# Step 7: Move signed APK to provision directory (replace existing)
echo ""
echo "Moving signed APK to provision directory..."
if [ -f "$FINAL_APK" ]; then
    rm -f "$FINAL_APK"
fi
mv "$SIGNED_APK" "$FINAL_APK"

# Step 8: Print summary
echo ""
echo "=========================================="
echo "Build and Sign Complete!"
echo "=========================================="
echo "Signed APK: $FINAL_APK"
echo "APK Size: $(du -h "$FINAL_APK" | cut -f1)"
echo ""
echo "To verify the signature manually:"
echo "  $APKSIGNER_PATH verify $FINAL_APK"
echo ""

