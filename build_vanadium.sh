MANIFEST=$1

# If we don't detect the SDK installation and if we have a set manifest
if [[ ! -d "$HOME/android/sdk" && $MANIFEST != "development" ]]; then
    install_android_sdk
    VERSION_CODE=$(aapt2 dump badging "external/vanadium/prebuilt/arm64/TrichromeChrome.apk" | grep -oP "versionName='\K\d+")
fi

# Set build trees
mkdir -p /opt/build/vanadium /opt/build/depot_tools /opt/build/chromium

git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git /opt/build/depot_tools
git clone https://github.com/GrapheneOS/Vanadium.git /opt/build/vanadium 

if [[ $MANIFEST != "development" ]]; then
    cd /opt/build/vanadium
    git checkout tags/"${VERSION_CODE}"
fi

export PATH="$PATH:/opt/build/depot_tools"

cd /opt/build/chromium
fetch --nohooks --no-history android
cd src
git fetch --tags

if [[ $MANIFEST != "development" ]]; then
    git checkout tags/"${VERSION_CODE}"
fi

git am --whitespace=nowarn --keep-non-patch /opt/build/vanadium/patches/*.patch

gclient sync -D --with_branch_heads --with_tags --jobs 32

gn args out/Default

chrt -b 0 ninja -C out/Default/ trichrome_webview_64_32_apk trichrome_chrome_64_32_apk trichrome_library_64_32_apk

../generate-release.sh out
