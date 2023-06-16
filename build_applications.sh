#!/bin/bash

MANIFEST=$1
APPS_TO_BUILD=$2

# Download and build the applications
if [ "$APPS_TO_BUILD" != "all" ]; then
    IFS=" " read -r -a apps_array <<< "$APPS_TO_BUILD"
else
    apps_array=("Auditor" "Apps" "Camera" "PdfViewer" "TalkBack" "GmsCompat")
fi

for APP in "${apps_array[@]}"; do
    mkdir -p /opt/build/apps/
    cd /opt/build/apps/

    clone_repository() {
        local app_dir="$1"
        local repo_url="https://github.com/GrapheneOS/${app_dir}.git"
        git clone "$repo_url" 
        cd "$app_dir"
    }

    if [ "$APP" = "GmsCompat" ]; then
        clone_repository "platform_packages_apps_GmsCompat"
    else
        clone_repository "$APP"
    fi

    # If MANIFEST is development, build newest
    if [[ $MANIFEST == "development" ]]; then
        if [ "$APP" = "GmsCompat" ]; then
            git checkout tags/"$(git describe --tags --abbrev=0)"
            cd config-holder/
        else
            git checkout tags/"$(git describe --tags --abbrev=0)"
        fi
    # If not, use the prebuilt APK's versionCode and checkout the tag related
    else
        if [ "$APP" = "GmsCompat" ]; then
            VERSION_CODE=$(aapt2 dump badging "external/${APP}/prebuilt/${APP}Config.apk" | grep -oP "versionCode='\K\d+")
            git checkout tags/"${VERSION_CODE}"
            cd config-holder/
        else
            VERSION_CODE=$(aapt2 dump badging "external/${APP}/prebuilt/${APP}.apk" | grep -oP "versionCode='\K\d+")
            git checkout tags/"${VERSION_CODE}"
        fi
    fi

    GRADLE_VERSION=$(awk -F'/' '/^distributionUrl=/ {print $NF}' gradle/wrapper/gradle-wrapper.properties | cut -d'-' -f2)
    GRADLE_CHECKSUM=$(awk -F'=' '/^distributionSha256Sum=/ {print $NF}' gradle/wrapper/gradle-wrapper.properties)

    ./gradlew wrapper --gradle-version="$GRADLE_VERSION" --gradle-distribution-sha256-sum="$GRADLE_CHECKSUM"
    ./gradlew wrapper --gradle-version="$GRADLE_VERSION" --gradle-distribution-sha256-sum="$GRADLE_CHECKSUM"

    ./gradlew build

    # TODO: export the built application to external/$APP/prebuilt/$APP.apk

    cd /opt/build/grapheneos
done
