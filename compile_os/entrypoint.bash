#!/bin/bash

set -o errexit -o pipefail

# Set default values 
DEVICES_TO_BUILD="${DEVICES_TO_BUILD:-"raven"}"
MANIFESTS_FOR_BUILD="${MANIFESTS_FOR_BUILD:-""}"
BUILD_TARGET="${BUILD_TARGET:-"stable"}"
BUILD_NUMBER="${BUILD_NUMBER:-""}"
BUILD_DATETIME="${BUILD_DATETIME:-""}"
BUILD_ID="${BUILD_ID:-""}"
USE_PREBUILT_KERNEL="${USE_PREBUILT_KERNEL:-false}"
KERNEL_MANIFEST="${KERNEL_MANIFEST:-""}"
USE_PREBUILT_APPS="${USE_PREBUILT_APPS:-false}"
PACKAGE_OS="${PACKAGE_OS:-true}"
APPS_TO_BUILD="${APPS_TO_BUILD:-all}"
USE_AOSP_TEST_KEYS="${USE_AOSP_TEST_KEYS:-false}"
OFFICIAL_BUILD="${OFFICIAL_BUILD:-true}"
NPROC_SYNC="${NPROC_SYNC:-8}"
NPROC_BUILD="${NPROC_BUILD:-8}"
SKIP_GRAPHENEOS="${SKIP_GRAPHENEOS:-false}"
BUILD_VANADIUM="${BUILD_VANADIUM:-false}"
VANADIUM_MANIFEST="${VANADIUM_MANIFEST:-""}"
GIT_USERNAME="${GIT_USERNAME:-grapheneos}"
GIT_EMAILADDRESS="${GIT_EMAILADDRESS:-grapheneos-build@localhost}"

# Configure Git user name and email and gitcookies
git config --global user.name "$GIT_USERNAME"
git config --global user.email "$GIT_EMAILADDRESS"

if [ -f "/.gitcookies" ]; then
    git config --global http.cookiefile /.gitcookies
fi

# Function to check breaking environment conditions
check_breaking_env() {
    IFS=" " read -r -a device_array <<< "$DEVICES_TO_BUILD"
    IFS=" " read -r -a manifest_array <<< "$MANIFESTS_FOR_BUILD"
    IFS=" " read -r -a apps_array <<< "$APPS_TO_BUILD"

    # This implies either build method one or three.
    if [[ ${#device_array[@]} != ${#manifest_array[@]} ]]; then
        # If this isn't build method one...
        if [[ -z $BUILD_TARGET ]]; then
            # If this isn't build method three...
            if [[ -z $BUILD_NUMBER || -z $BUILD_DATETIME || -z $BUILD_ID ]]; then
                echo "Cannot run: there must be an equal amount of devices to manifests unless you specify BUILD_TARGET=stable or BUILD_TARGET=development OR you specify BUILD_NUMBER and BUILD_DATETIME and BUILD_ID."
                exit 1
            fi
        else
            # If this is a combination of build method one and three...
            if [[ ! -z $BUILD_NUMBER || ! -z $BUILD_DATETIME || ! -z $BUILD_ID ]]; then
                echo "You have specified a BUILD_NUMBER, BUILD_DATETIME, and BUILD_ID as well as a BUILD_TARGET. BUILD_TARGET is for one-off builds of the latest builds and development builds directly from git."
                exit 1
            fi
        fi
    # If the BUILD_TARGET exists and is not an acceptable value...
    elif [[ $BUILD_TARGET != "stable" && $BUILD_TARGET != "development" && $BUILD_TARGET != "beta" && $BUILD_TARGET != "alpha" && $BUILD_TARGET != "testing" && ! -z $BUILD_TARGET ]]; then
        echo "BUILD_TARGET can currently only be set to stable, beta, alpha, and development."
        exit 1
    # TODO: flesh out
    elif [[ $SKIP_GRAPHENEOS == "true" ]]; then
        if [[ $USE_PREBUILT_KERNEL == "false" && $KERNEL_MANIFEST == "" ]]; then
            echo "Provide a KERNEL_MANIFEST to build the kernel from"
            exit 1
        fi

        if [[ $BUILD_VANADIUM == "false" && $VANADIUM_MANIFEST == "" ]]; then
            echo "Provide a VANADIUM_MANIFEST to build Vanadium from"
            exit 1
        fi
    # If we are going for a reproducible build...
    elif [[ $OFFICIAL_BUILD == "true" ]]; then
        # If a local_manifest directory exists...
        if [[ -d "/local_manifests" ]]; then
            echo "Official builds do not use custom manifests. Please remove your bind mount and retry."
            exit 1
        fi

        # If build method two was detected... 
        if [[ ! -z $MANIFESTS_FOR_BUILD ]]; then
            echo "Official builds imply reproducibility. This method of building is not compatible."
            exit 1
        fi
    # If we want a final ZIP and if we don't find the keys folder and we aren't using the test keys...
    elif [[ $PACKAGE_OS == "true" && ! -d "/opt/build/grapheneos/keys" && $USE_AOSP_TEST_KEYS == "false" ]]; then
        echo "Packaging the OS requires signed keys to be available. Check your bind mount and retry or use GrapheneOS test keys (not recommended)."
        exit 1
    # If we want a final ZIP and if we both keys set up and we are using the test keys...
    elif [[ $PACKAGE_OS == "true" && -d "/opt/build/grapheneos/keys" && $USE_AOSP_TEST_KEYS == "true" ]]; then
        echo "Packaging the OS requires signed keys. You have bind mounted your own keys and selected to use the AOSP test keys. Please set USE_AOSP_TEST_KEYS to false and try again."
        exit 1
    # If we want to build the applications and we don't have what applications to build...
    elif [[ $USE_PREBUILT_APPS == "false" && -z $APPS_TO_BUILD ]]; then
        echo "If you want to build the applications, ensure that you set APPS_TO_BUILD to what you want to build. If you want to build all, set the variable to all."
        exit 1
    fi

    # For any potential application in APPS_TO_BUILD, check to see if they are acceptable values.
    for app in "${apps_array[@]}"; do
        if [[ $app != "Auditor" && $app != "Apps" && $app != "Camera" && $app != "PdfViewer" && $app != "TalkBack" && $app != "GmsCompat" && $app != "all" ]]; then
            echo "$app is not a valid application. The only valid applications are: Auditor, Apps, Camera, PdfViewer, TalkBack, GmsCompat. You can also set it to 'all' and it will build all the applications."
            exit 1
        fi
    done

    # For any potential devices in DEVICES_TO_BUILD, check to see if they are acceptable values.
    for device in "${device_array[@]}"; do
        if [[ $device != "coral" && $device != "sunfish" && $device != "bramble" && $device != "redfin" && $device != "barbet" && $device != "oriole" && $device != "raven" && $device != "bluejay" && $device != "panther" && $device != "cheetah" && $device != "lynx" ]]; then
            echo "$device is not a valid device. The only valid devices are: coral, sunfish, bramble, redfin, barbet, oriole, raven, bluejay, panther, cheetah, lynx."
            exit 1
        fi
    done
}

# Ping the official update server and get the current metadata.
get_metadata () {
    local DEVICE=$1
    local CHANNEL=$2

    URL="https://releases.grapheneos.org/${DEVICE}-${CHANNEL}"

    read -r BUILD_NUMBER BUILD_DATETIME BUILD_ID _ < <(echo $(curl -s $URL))

    export BUILD_NUMBER="$BUILD_NUMBER"
    export BUILD_DATETIME="$BUILD_DATETIME"
    export BUILD_ID="$BUILD_ID"
    export MANIFEST_FROM_METADATA="${BUILD_ID}.${BUILD_NUMBER}"
}

check_breaking_env

if [[ $SKIP_GRAPHENEOS == "true" ]]; then
    for ((i = 0; i < ${#device_array[@]}; i++)); do 
        if [[ "$USE_PREBUILT_KERNEL" == "false" ]]; then
            echo "[INFO] Building Kernel for "${device_array[i]}" with tag ${KERNEL_MANIFEST}"
            source build_kernel.sh "${device_array[i]}" $KERNEL_MANIFEST
        fi

        if [[ "$USE_PREBUILT_APPS" == "false" ]]; then
            echo "[INFO] Installing SDKManager"
            source install_sdk.sh
            echo "[INFO] Building applications"
            source build_applications.sh "development" $APPS_TO_BUILD
        fi

        if [ "$BUILD_VANADIUM" = "true" ]; then
            echo "[INFO] Building Vanadium"
            source build_vanadium.sh $VANADIUM_MANIFEST
        fi
    done
else 
    for ((i = 0; i < ${#device_array[@]}; i++)); do

        # This is for the case of "I have a BUILD_NUMBER, BUILD_DATETIME and BUILD_ID and I don't want to check against MANIFESTS_TO_BUILD or a BUILD_TARGET".
        if [[ -z $BUILD_TARGET && -z $MANIFESTS_FOR_BUILD ]]; then
            source compile_os.sh "${device_array[i]}" "$BUILD_ID" "${BUILD_ID}.${BUILD_NUMBER}"
        fi

        case $BUILD_TARGET in
            stable|beta|alpha|testing)
                get_metadata "${device_array[i]}" "$BUILD_TARGET"
                source compile_os.sh "${device_array[i]}" "$BUILD_ID" "$MANIFEST_FROM_METADATA"
                ;;
            development)
                source compile_os.sh "${device_array[i]}" "$BUILD_ID" "development"
                ;;
            *)
                BUILD_ID=$(echo "${manifest_array[i]}" | cut -d'.' -f1-3)
                source compile_os.sh "${device_array[i]}" "$BUILD_ID" "${manifest_array[i]}"
                ;;
        esac

        if [ "$PACKAGE_OS" = "true" ]; then
            source package_os.sh "${device_array[i]}"
        fi
        
    done
fi
