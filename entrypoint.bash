#!/bin/bash

set -o errexit -o pipefail

sudo chown builduser:builduser /opt/build/grapheneos/

# Checking ENV variables 

# There must be at least one device and manifest defined. 
    # If there is more than one defined, there needs to be an equal amount of manifests. 
    # When stable or development targets are selected, we do not need manifests.
    # If BUILD_TARGET isn't enabled, we rely on a specific BUILD_NUMBER, BUILD_ID and BUILD_DATETIME if OFFICIAL_BUILD is true

# Build target will override the manifest. If BUILD_TARGET is stable, we'll use get-metadata.sh to get what we need. If it's set to development, that will be generated.
# BUILD_BRANCH does not matter in context of building.
# Kernels should be built automatically. 
# Apps should also be included automatically.
# SKIP_GRAPHENEOS will be false. The only time this will change is if you're building the applications itself.
# OFFICIAL_BUILD will be true with reproducibility in mind.

check_breaking_env () {
    IFS=" " read -r -a device_array <<< "$DEVICES_TO_BUILD"
    IFS=" " read -r -a manifest_array <<< "$MANIFESTS_FOR_BUILD"

    if [ "${#device_array[@]}" != "${#manifest_array[@]}" ]; then
        if [ -z "$BUILD_TARGET" ]; then
            if [ -z "$BUILD_NUMBER" ] || [ -z "$BUILD_DATETIME" ] || [ -z "$BUILD_ID" ]; then
                echo "Cannot run: there must be an equal amount of devices to manifests unless you specify BUILD_TARGET=stable or BUILD_TARGET=development OR you specify BUILD_NUMBER and BUILD_DATETIME and BUILD_ID."
                exit 1
            fi
        else 
            if ! [ -z "$BUILD_NUMBER" ] || ! [ -z "$BUILD_DATETIME" ] || ! [ -z "$BUILD_ID" ]; then
                echo "You have specified a BUILD_NUMBER, BUILD_DATETIME and BUILD_ID as well as a BUILD_TARGET. BUILD_TARGET is for one-off builds of the latest builds and development builds directly from git."
                exit 1
            fi
        fi
    elif [ "$BUILD_TARGET" != "stable" ] && [ "$BUILD_TARGET" != "development" ] && [ "$BUILD_TARGET" != "beta" ] && [ "$BUILD_TARGET" != "alpha" ] && [ "$BUILD_TARGET" != "testing" ] && ! [ -z "$BUILD_TARGET "]; then
        echo "BUILD_TARGET can currently only be set to stable, beta, alpha, and development."
        exit 1
    elif [ "$SKIP_GRAPHENEOS" = "true" ]; then
        echo "Currently unsupported."
        exit 1
    elif [ "$OFFICIAL_BUILD" = "true" ] && [ -d ".repo/local_manifests" ]; then
        echo "Official builds do not use custom manifests. Please remove your bind mount and retry."
        exit 1
    elif [ "$PACKAGE_OS" = "true" ] && ! [ -d "/opt/build/grapheneos/keys" ]; then
        echo "Packaging the OS requires signed keys to be available. Check your bind mount and retry."
        exit 1
    fi
}

get_metadata () {
    DEVICE=$1
    CHANNEL=$2

    URL="https://releases.grapheneos.org/${DEVICE}-${CHANNEL}"

    read -r BUILD_NUMBER BUILD_DATETIME BUILD_ID _ < <(echo $(curl -s $URL))

    export BUILD_NUMBER="$BUILD_NUMBER"
    export BUILD_DATETIME="$BUILD_DATETIME"
    export BUILD_ID="$BUILD_ID"
}

compile_os () {
    local DEVICE=$1
    local BUILD_ID=$2
    local MANIFEST=$3

    echo "Device we are building for: $DEVICE"
    echo "Stock Build ID associated with the device: $BUILD_ID"
    echo "Manifest from GrapheneOS to build from: $MANIFEST"

    echo "[INFO] Downloading and verifying manifest"
    if [ "$MANIFEST" = "development" ]; then
        case $DEVICE in
            oriole|raven|bluejay|panther|cheetah)
                repo init -u https://github.com/GrapheneOS/platform_manifest.git -b 13
                ;;
            lynx)
                repo init -u https://github.com/GrapheneOS/platform_manifest.git -b 13-lynx
                ;;
            *)
                repo init -u https://github.com/GrapheneOS/platform_manifest.git -b 13-coral
                ;;
        esac
    else
        repo init -u https://github.com/GrapheneOS/platform_manifest.git -b refs/tags/$MANIFEST
        mkdir -p ~/.ssh && curl https://grapheneos.org/allowed_signers > ~/.ssh/grapheneos_allowed_signers
        (cd .repo/manifests && git config gpg.ssh.allowedSignersFile ~/.ssh/grapheneos_allowed_signers && git verify-tag "$(git describe)")
    fi

    echo "[INFO] Syncing GrapheneOS tree"
    repo sync -j${NPROC_SYNC}

    if [ "$USE_PREBUILT_KERNEL" = "false" ]; then
        echo "[INFO] Building Kernel for ${DEVICE}"
        build_kernel $DEVICE
    fi

    echo "[INFO] Setting up adevtool"
    yarn install --cwd vendor/adevtool/
    source script/envsetup.sh
    m aapt2

    echo "[INFO] Obtaining proprietary files with adevtool"
    vendor/adevtool/bin/run download vendor/adevtool/dl/ -d $DEVICE -b $BUILD_ID -t factory ota
    sudo rm -rf  vendor/adevtool/dl/unpacked/$DEVICE-${BUILD_ID,,}/
    sudo vendor/adevtool/scripts/unpack-images.sh vendor/adevtool/dl/$DEVICE-${BUILD_ID,,}-*.zip
    sudo vendor/adevtool/bin/run generate-all vendor/adevtool/config/$DEVICE.yml -c vendor/state/$DEVICE.json -s vendor/adevtool/dl/unpacked/$DEVICE-${BUILD_ID,,}/
    sudo chown -R builduser:builduser vendor/{google_devices,adevtool}
    vendor/adevtool/bin/run ota-firmware vendor/adevtool/config/$DEVICE.yml -f vendor/adevtool/dl/$DEVICE-ota-${BUILD_ID,,}-*.zip

    echo "[INFO] Building OS"
    source script/envsetup.sh
    # We are not going to support eng or userdebug builds
    choosecombo release $DEVICE user
    # At this point, the environment variables BUILD_DATETIME and BUILD_NUMBER are pulled when OFFICIAL_BUILD is true
    if [ "$DEVICE" = "oriole" || "$DEVICE" = "raven" || "$DEVICE" = "bluejay" ]; then
        m vendorbootimage target-files-package otatools-package -j${NPROC_BUILD}
    elif [ "$DEVICE" = "panther" || "$DEVICE" = "cheetah" || "$DEVICE" = "lynx" ]; then
        m vendorbootimage vendorkernelbootimage target-files-package otatools-package -j${NPROC_BUILD}
    else
         m target-files-package otatools-package -j${NPROC_BUILD}
    fi
    echo "[INFO] OS built"
}

build_kernel () {
    DEVICE=$1

    case $DEVICE in
        coral)
            mkdir -p android/kernel/coral
            cd android/kernel/coral
            repo init -u https://github.com/GrapheneOS/kernel_manifest-coral.git -b 13
            repo sync -j${NPROC_SYNC}
            KBUILD_BUILD_VERSION=1 KBUILD_BUILD_USER=build-user KBUILD_BUILD_HOST=build-host KBUILD_BUILD_TIMESTAMP="Thu 01 Jan 1970 12:00:00 AM UTC" BUILD_CONFIG=private/msm-google/build.config.floral build/build.sh
            rsync -av --delete out/android-msm-pixel-4.14/dist/ device/google/coral-kernel/
            ;;
        sunfish)
            mkdir -p android/kernel/coral
            cd android/kernel/coral
            repo init -u https://github.com/GrapheneOS/kernel_manifest-coral.git -b 13
            repo sync -j${NPROC_SYNC}
            KBUILD_BUILD_VERSION=1 KBUILD_BUILD_USER=build-user KBUILD_BUILD_HOST=build-host KBUILD_BUILD_TIMESTAMP="Thu 01 Jan 1970 12:00:00 AM UTC" BUILD_CONFIG=private/msm-google/build.config.sunfish build/build.sh
            rsync -av --delete out/android-msm-pixel-4.14/dist/ device/google/sunfish-kernel/
            ;;
        bramble|redfin|barbet)
            mkdir -p android/kernel/redbull
            cd android/kernel/redbull
            repo init -u https://github.com/GrapheneOS/kernel_manifest-redbull.git -b 13
            repo sync -j${NPROC_SYNC}
            BUILD_CONFIG=private/msm-google/build.config.redbull.vintf build/build.sh
            rsync -av --delete out/android-msm-pixel-4.19/dist/ device/google/redbull-kernel/vintf/
            ;;
        oriole|raven)
            mkdir -p android/kernel/raviole
            cd android/kernel/raviole
            repo init -u https://github.com/GrapheneOS/kernel_manifest-raviole.git -b 13
            repo sync -j${NPROC_SYNC}
            LTO=full BUILD_AOSP_KERNEL=1 ./build_slider.sh
            rsync -av --delete out/mixed/dist/ device/google/raviole-kernel/
            ;;
        bluejay)
            mkdir -p android/kernel/bluejay
            cd android/kernel/bluejay
            repo init -u https://github.com/GrapheneOS/kernel_manifest-bluejay.git -b 13
            repo sync -j${NPROC_SYNC}
            LTO=full BUILD_AOSP_KERNEL=1 ./build_bluejay.sh
            rsync -av --delete out/mixed/dist/ device/google/bluejay-kernel/
            ;;
        panther|cheetah)
            mkdir -p android/kernel/pantah
            cd android/kernel/pantah
            repo init -u https://github.com/GrapheneOS/kernel_manifest-pantah.git -b 13
            repo sync -j${NPROC_SYNC}
            LTO=full BUILD_AOSP_KERNEL=1 ./build_cloudripper.sh
            rsync -av --delete out/mixed/dist/ device/google/pantah-kernel/
            ;;
        lynx)
            mkdir -p android/kernel/lynx
            cd android/kernel/lynx
            repo init -u https://github.com/GrapheneOS/kernel_manifest-lynx.git -b 13-lynx
            repo sync -j${NPROC_SYNC}
            LTO=full BUILD_AOSP_KERNEL=1 ./build_lynx.sh
            rsync -av --delete out/mixed/dist/ device/google/lynx-kernel/
            ;;
    esac
}

# build_vanadium () {
#     git clone https://github.com/GrapheneOS/Vanadium.git
#     cd Vanadium
#     git checkout CORRECT_BRANCH_OR_TAG
# }

# verify_os() {
#
# }

package_os () {
    DEVICE=$1
    # https://github.com/GrapheneOS/platform_development.git 
    # Currently, the plan is to include your own made keys. This is here just in case we decide to do this on the fly which will definitely not be recommended at all.

    # Packaging also signs the OS as well. 
    script/release.sh $DEVICE
}

check_breaking_env

for ((i = 0; i < ${#device_array[@]}; i++)); do
    case $BUILD_TARGET in
        stable|beta|alpha|testing)
            get_metadata "${device_array[i]}" "$BUILD_TARGET"
            compile_os "${device_array[i]}" "$BUILD_ID" "${manifest_array[i]}"
            ;;
        development)
            compile_os "${device_array[i]}" "$BUILD_ID" "development"
            ;;
        *)
            compile_os "${device_array[i]}" "$BUILD_ID" "${manifest_array[i]}"
            ;;
    esac

    if [ "$PACKAGE_OS" = "true" ]; then
        package_os "${device_array[i]}"
    fi
done