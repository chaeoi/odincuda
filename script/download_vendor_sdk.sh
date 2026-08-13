#!/usr/bin/env bash

# Download the vendor SDK required by the Odin ROS driver.
set -Eeuo pipefail
umask 022

GITWARP_ROOT="${GITWARP_ROOT:-https://gitwarp.canghai.org}"
SDK_REF="v0.14.0"
PACKAGE_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SDK_DIR="${PACKAGE_DIR}/lib"

SDK_ARM_URL="${GITWARP_ROOT}/raw.githubusercontent.com/manifoldsdk/odin_ros_driver/${SDK_REF}/lib/liblydHostApi_arm.a"
SDK_AMD_URL="${GITWARP_ROOT}/raw.githubusercontent.com/manifoldsdk/odin_ros_driver/${SDK_REF}/lib/liblydHostApi_amd.a"
SDK_ARM_SHA256="4e31dcf09afcd0c0028e3f424182195dad4fb1f5d631e1f7e6d066eabb344724"
SDK_AMD_SHA256="6f557945afa792132f2c6c97518da653c1fdcb07b2f8bf4b3cfa9e4bb33aeabe"

ensure_checked() {
    local url="$1" expected="$2" destination="$3" temporary actual
    if [[ -s "$destination" ]]; then
        actual="$(sha256sum "$destination" | awk '{print $1}')"
        if [[ "$actual" == "$expected" ]]; then
            echo "Using verified SDK: $destination"
            return 0
        fi
        echo "Replacing SDK with unexpected checksum: $destination" >&2
    fi
    temporary="$(mktemp "${destination}.tmp.XXXXXX")"
    trap 'rm -f "$temporary"' RETURN
    curl -fL --retry 4 --retry-delay 2 "$url" -o "$temporary"
    actual="$(sha256sum "$temporary" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "SDK checksum mismatch: $destination" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        return 1
    fi
    mv -f "$temporary" "$destination"
    trap - RETURN
}

if [[ ! -f "${PACKAGE_DIR}/CMakeLists.txt" ]]; then
    echo "Usage: $0 [path/to/odin_ros_driver]" >&2
    exit 2
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
    echo "Error: curl and sha256sum are required." >&2
    exit 1
fi

install -d "$SDK_DIR"
echo "Downloading and verifying Odin vendor SDK (${SDK_REF})"
ensure_checked "$SDK_ARM_URL" "$SDK_ARM_SHA256" "$SDK_DIR/liblydHostApi_arm.a"
ensure_checked "$SDK_AMD_URL" "$SDK_AMD_SHA256" "$SDK_DIR/liblydHostApi_amd.a"
echo "SDK installed in $SDK_DIR"
