#!/bin/bash

#
# Based on pkgAndNotarize.sh
# Copyright (c) 2019 - Armin Briegel - Scripting OS X
#

cleanup() {
  rm -rf dmg-build certificate.p12 build.keychain
}

abort() {
  echo "ERROR: ${1}!"
  if [ "$2" != "" ]; then
    echo "Hint: ${2}."
  fi

  revertkeychain
  cleanup
  exit 1
}

revertkeychain() {
  if [ -f "${syskeychain}" ]; then
    echo "Reverting keychain..."
    security default-keychain -s "${syskeychain}" || echo "WARN: Failed to revert keychain!"
    security delete-keychain "${workdir}/build.keychain" || echo "WARN: Failed to delete keychain!"
  fi
}

downloadcert() {
  if [ "$MAC_CERTIFICATE_PASSWORD" = "" ]; then
    abort "Unable to find macOS certificate password" "Set MAC_CERTIFICATE_PASSWORD environment variable"
  fi

  curl -OL "https://github.com/acidanthera/ocbuild/raw/master/codesign/certificate.p12" || abort "Failed to download certificates"

  local pw
  pw=$(uuidgen)
  rm -f "${workdir}/build.keychain"
  security create-keychain -p "${pw}" "${workdir}/build.keychain" || abort "Cannot create keychain"
  security default-keychain -s "${workdir}/build.keychain" || abort "Cannot set default keychain"
  security unlock-keychain -p "${pw}" "${workdir}/build.keychain" || abort "Cannot unlock keychain"
  security import certificate.p12 -k "${workdir}/build.keychain" -P "$MAC_CERTIFICATE_PASSWORD" -T /usr/bin/codesign || abort "Cannot import certificate"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${pw}" "${workdir}/build.keychain" || abort "Cannot set keychain key list"
}

compressapp() {
  if [ "$(which create-dmg)" = "" ]; then
    abort "Unable to locate create-dmg command"
  fi

  mkdir "dmg-build" || abort "Unable to create dmg-build directory"

  apppath="$1"
  outfile="$2"
  appname="$(basename "${apppath}")"

  cp -a "${apppath}" "dmg-build/" || abort "Unable to copy application to dmg-build"

  create-dmg \
    --volname "${appname/.app/}" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon-size 100 \
    --icon "${appname}" 200 190 \
    --hide-extension "${appname}" \
    --app-drop-link 600 185 \
    "${outfile}" \
    "dmg-build/" || abort "Unable to create dmg file"

  rm -rf dmg-build
}

requeststatus() { # $1: requestUUID
  requestUUID="${1}"
  req_status=$(xcrun altool --notarization-info "$requestUUID" \
                            --username "${MAC_ACCOUNT_NAME}" \
                            --password "@env:MAC_ACCOUNT_PASSWORD" 2>&1 \
               | awk -F ': ' '/Status:/ { print $2; }' )
  echo "$req_status"
}

notarizefile() { # $1: path to file to notarize, $2: identifier
  filepath="${1}"
  identifier="${2}"

  if [ "$MAC_ACCOUNT_NAME" = "" ]; then
    abort "Unable to find Apple account name" "Set MAC_ACCOUNT_NAME environment variable"
  fi

  if [ "$MAC_ACCOUNT_PASSWORD" = "" ]; then
    abort "Unable to find Apple account namee" "Set MAC_ACCOUNT_PASSWORD environment variable"
  fi

  asc_provider=$(security find-certificate -a -c "Developer ID" "${workdir}/build.keychain" | grep "alis" | head -1 | cut -d'"' -f4 | cut -d'(' -f2 | cut -d')' -f1)
  if [ "$asc_provider" = "" ]; then
    abort "Unable to find ASC provider"
  fi

  # Upload file
  echo "Uploading ${filepath} for notarization for ${asc_provider}"
  requestUUID=$(xcrun altool --notarize-app \
                             --primary-bundle-id "$identifier" \
                             --username "${MAC_ACCOUNT_NAME}" \
                             --password "@env:MAC_ACCOUNT_PASSWORD" \
                             --asc-provider "${asc_provider}" \
                             --file "$filepath" 2>&1 \
                | awk '/RequestUUID/ { print $NF; }')

  echo "Notarization RequestUUID: $requestUUID"

  if [ "$requestUUID" = "" ]; then
    abort "Could not upload for notarization"
  fi

  # Wait for status to be not "in progress" any more
  request_status="in progress"
  while [ "$request_status" = "in progress" ]; do
    printf "waiting... "
    sleep 10
    request_status=$(requeststatus "$requestUUID")
    echo "$request_status"
  done

  # Print status information
  xcrun altool --notarization-info "$requestUUID" \
               --username "${MAC_ACCOUNT_NAME}" \
               --password "@env:MAC_ACCOUNT_PASSWORD"
  echo

  if [ "$request_status" != "success" ]; then
    abort "Could not notarize ${filepath}"
  fi
}

cleanup

# Obtain system data.
echo "Gathering system data..."
workdir=$(pwd)
syskeychain=$(security default-keychain | xargs echo)
if [ ! -f "${syskeychain}" ]; then
  abort "Unable to locate default keychain at ${syskeychain}"
fi

# Obtain application data.
echo "Gathering application data..."
if [ ! -d "$1" ]; then
  abort "Unable to locate application to sign" "Pass application path as an argument"
fi

cd "$1" || abort "Cannot get app full path"
apppath="$(pwd)"
cd - || abort "Cannot switch directory back"

if [ "$2" = "" ]; then
  abort "Missing archive filename for target file" "Pass path to archived file as an argument"
fi

# TODO: Accept relative paths.
apppkg="$2"
rm -f "${apppkg}"

identifier="$(defaults read "${apppath}/Contents/Info.plist" CFBundleIdentifier)"
if [ "$identifier" = "" ]; then
  abort "Unable to locate application identifier" "Set CFBundleIdentifier in Info.plist"
fi

# Obtain certificate data.
echo "Downloading the certificates..."
downloadcert

# Codesign the application.
echo "Codesigning application..."
/usr/bin/codesign --force --deep --options runtime -s "Developer ID" "${apppath}" || abort "Unable to sign application"

# Compress the application.
echo "Compressing application..."
compressapp "${apppath}" "${apppkg}"

# Notarize the application.
notarizefile "${apppkg}" "${identifier}"

# Staple the application.
echo "Stapling application..."
xcrun stapler staple "${apppkg}"

echo 'All done!'
revertkeychain
cleanup
