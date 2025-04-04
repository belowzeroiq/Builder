#!/bin/bash
set -e

# ===== Configuration =====
# Essential Variables (should be set as env vars or defined here)
ROM_NAME="${MAKEFILENAME%%_*}"  # Extract ROM base name
CCACHE_DIR=${HOME}/.ccache
CCACHE_TAR="${ROM_NAME}.ccache.tar.gz"
CCACHE_COPY_DIR="$HOME/ccache_copy"

SAFE_TIME=5760  # 1 hour and 35 minutes in seconds
LOG_FILE="build.log"
OTA_ZIP="${OUT_DIR}/target/product/${DEVICE_CODENAME}/*.zip"

# ===== 64-bit Enforcement =====
export TARGET_ARCH=arm64
export TARGET_SUPPORTS_32_BIT_APPS=false

# ===== Functions =====

# Cleanup handler
cleanup() {
    echo "Performing cleanup..."
    # Kill background processes
    kill "$TIMER_PID" 2>/dev/null || true
    # Remove temporary files
    rm -rf "$CCACHE_COPY_DIR" "$CCACHE_TAR"
}
trap cleanup EXIT

setup_ccache() {
    echo "Setting up ccache..."
    export USE_CCACHE=1
    ccache -M 50G
    ccache -z
}

download_ccache() {
    echo "Checking for existing ccache for ${ROM_NAME} on PixelDrain..."
    response=$(curl -s -H "Authorization: Basic $(echo -n ":$PIXELDRAIN_API_KEY" | base64)" \
        "https://pixeldrain.com/api/user/files") || return 1

    ccache_file_id=$(echo "$response" | jq -r --arg CCACHE_TAR "$CCACHE_TAR" \
        '[.files[] | select(.name | test("^" + $CCACHE_TAR + "$"))] | sort_by(.date_upload) | last | .id')
      
    if [ -z "$ccache_file_id" ] || [ "$ccache_file_id" = "null" ]; then
        echo "No previous ccache found for ${ROM_NAME}, starting fresh."
        return 1
    fi

    echo "Downloading ccache (ID: $ccache_file_id)..."
    if curl -L -o "$CCACHE_TAR" "https://pixeldrain.com/api/file/$ccache_file_id?download"; then
        mkdir -p "$CCACHE_DIR"
        tar -xzf "$CCACHE_TAR" -C "$CCACHE_DIR"
        rm -f "$CCACHE_TAR"
        return 0
    else
        rm -f "$CCACHE_TAR"
        return 1
    fi
}

compress_and_upload_ccache() {
    echo "Creating safe copy of ccache for ${ROM_NAME}..."
    mkdir -p "$CCACHE_COPY_DIR"
    rsync -a --delete "$CCACHE_DIR/" "$CCACHE_COPY_DIR/" || cp -a "$CCACHE_DIR/." "$CCACHE_COPY_DIR/"

    echo "Compressing ccache..."
    tar -czf "$CCACHE_TAR" -C "$CCACHE_COPY_DIR" . || return 1

    echo "Uploading ${CCACHE_TAR} to PixelDrain..."
    response=$(curl -s -X POST \
        -H "Authorization: Basic $(echo -n ":$PIXELDRAIN_API_KEY" | base64)" \
        -F "file=@$CCACHE_TAR" \
        "https://pixeldrain.com/api/file") || return 1

    file_id=$(echo "$response" | jq -r '.id')
    if [ -n "$file_id" ] && [ "$file_id" != "null" ]; then
        echo "Uploaded: https://pixeldrain.com/u/$file_id"
    else
        echo "Failed to upload ccache!"
        return 1
    fi
}

upload_ota() {
    echo "Uploading OTA ZIP..."
    ota_file=$(find "out/target/product/${DEVICE_CODENAME}" -name "Arrow-v13.1-topaz*.zip" -type f | head -n 1)
    
    if [ -z "$ota_file" ]; then
        echo "No OTA ZIP file found!"
        return 1
    fi
    
    echo "Found OTA ZIP: $ota_file"
    response=$(curl -s -X POST \
        -H "Authorization: Basic $(echo -n ":$PIXELDRAIN_API_KEY" | base64)" \
        -F "file=@$ota_file" \
        "https://pixeldrain.com/api/file") || return 1
    
    file_id=$(echo "$response" | jq -r '.id')
    if [ -n "$file_id" ] && [ "$file_id" != "null" ]; then
        echo "OTA ZIP uploaded: https://pixeldrain.com/u/$file_id"
    else
        echo "Failed to upload OTA ZIP!"
        return 1
    fi
}

local start_time=$(date +%s)
monitor_time_with_logs() {
    local last_display_time=$start_time
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        local remaining=$((SAFE_TIME - elapsed))
        
        (( remaining <= 0 )) && {
            echo "Timeout approaching! Saving ccache..."
            compress_and_upload_ccache
            exit 0
        }
        
        if (( current_time - last_display_time >= 300 )); then
            echo -ne "\r$(date): Timer Running. Elapsed: ${elapsed}s / Timeout: ${SAFE_TIME}s | Remaining: ${remaining}s"
            echo -e "\n--- Latest Build Logs ---"
            tail -n 10 "$LOG_FILE"
            echo -e "-------------------------"
            last_display_time=$current_time
        fi
        sleep 1
    done
}

build() {
    echo "Starting build..."
    source build/envsetup.sh || . build/envsetup.sh
    lunch "$MAKEFILENAME-$VARIANT" || exit 1
    [ -n "$EXTRACMD" ] && eval "$EXTRACMD"
    $TARGET -j$(nproc --all) # >> "$LOG_FILE" 2>&1 || {
    #    echo "Build failed!"
    #    exit 1
    #}
}

# ===== Main Execution =====
{
    echo "===== Build Script Starting ====="
    echo "ROM: $MAKEFILENAME"
    echo "Device: $DEVICE_CODENAME"
    echo "Variant: $VARIANT"
    
    # Start monitoring
    : > "$LOG_FILE"
    monitor_time_with_logs &
    TIMER_PID=$!
    
    # Build process
    setup_ccache
    download_ccache || echo "No ccache found, starting fresh"
    build

    # Upload OTA ZIP
    upload_ota
    
    # Final ccache upload
    compress_and_upload_ccache
    
    echo "===== Build Completed Successfully ====="
} | tee -a "$LOG_FILE"
