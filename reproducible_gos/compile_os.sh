#!/bin/bash

DEVICE=$1
BUILD_ID=$2
MANIFEST=$3

echo "Device we are building for: $DEVICE"
echo "Stock Build ID associated with the device: $BUILD_ID"
echo "Manifest from GrapheneOS to build from: $MANIFEST"
echo
echo "OFFICIAL_BUILD status: $OFFICIAL_BUILD"
if [ "$OFFICIAL_BUILD" = "true" ]; then
    echo "BUILD_DATETIME is set to: $BUILD_DATETIME"
    echo "BUILD_NUMBER is set to: $BUILD_NUMBER"
    echo "BUILD_ID is set to: $BUILD_ID"
fi
echo "Are we using the AOSP Test Keys: $USE_AOSP_TEST_KEYS"
echo
echo "Are we using the prebuilt kernel: $USE_PREBUILT_KERNEL"
echo "Are we using the prebuilt applications: $USE_PREBUILT_APPS"
if [ "$APPS_TO_BUILD" != "all" ]; then
    IFS=" " read -r -a apps_array <<< "$APPS_TO_BUILD"
    echo "We are building the following apps: $apps_array"
fi
echo "Are we building Vanadium: $BUILD_VANADIUM"
echo
echo "NPROC Sync Count: $NPROC_SYNC"
echo "NPROC Build Count: $NPROC_BUILD"

echo "If any of these settings are blank, stop the build and make an issue or the build WILL fail."

sleep 10

echo "[INFO] Downloading and verifying manifest"
mkdir -p /opt/build/grapheneos/
cd /opt/build/grapheneos/

if [ "$MANIFEST" = "development" ]; then
    case $DEVICE in
        oriole|raven|bluejay|panther|cheetah|lynx)
            repo init -u https://github.com/GrapheneOS/platform_manifest.git -b 13
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
repo sync -j${NPROC_SYNC} --force-sync --no-clone-bundle --no-tags

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

echo "[INFO] Building Kernel for ${DEVICE} with tag ${MANIFEST}"
source build_kernel.sh $DEVICE $MANIFEST

echo "[INFO] Installing Android SDK Manager"
source install_sdk.sh
echo "[INFO] Building applications for ${DEVICE}"
source build_applications.sh

echo "[INFO] Building Vanadium"
source build_vanadium.sh $MANIFEST

echo "[INFO] Building OS"
source script/envsetup.sh
# We are not going to support eng or userdebug builds.
choosecombo release $DEVICE user
# At this point, the environment variables BUILD_DATETIME and BUILD_NUMBER are pulled when OFFICIAL_BUILD is true.
if [ "$DEVICE" = "oriole" || "$DEVICE" = "raven" || "$DEVICE" = "bluejay" ]; then
    m vendorbootimage target-files-package otatools-package -j${NPROC_BUILD}
elif [ "$DEVICE" = "panther" || "$DEVICE" = "cheetah" || "$DEVICE" = "lynx" ]; then
    m vendorbootimage vendorkernelbootimage target-files-package otatools-package -j${NPROC_BUILD}
else
    m target-files-package otatools-package -j${NPROC_BUILD}
fi
echo "[INFO] OS built"
