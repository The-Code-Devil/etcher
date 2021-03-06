#!/bin/bash

###
# Copyright 2016 Resin.io
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
###

# See http://www.davidpashley.com/articles/writing-robust-shell-scripts/
set -u
set -e
set -x

OS=`uname`
if [[ "$OS" != "Darwin" ]]; then
  echo "This script is only meant to be run in OS X" 1>&2
  exit 1
fi

if ! command -v bower 2>/dev/null; then
  echo "Dependency missing: bower" 1>&2
  exit 1
fi

ELECTRON_OSX_SIGN=./node_modules/.bin/electron-osx-sign
ELECTRON_PACKAGER=./node_modules/.bin/electron-packager
SIGN_IDENTITY_OSX="Developer ID Application: Rulemotion Ltd (66H43P8FRG)"
ELECTRON_VERSION=`node -e "console.log(require('./package.json').devDependencies['electron-prebuilt'])"`
APPLICATION_NAME=`node -e "console.log(require('./package.json').displayName)"`
APPLICATION_COPYRIGHT=`node -e "console.log(require('./package.json').copyright)"`
APPLICATION_VERSION=`node -e "console.log(require('./package.json').version)"`
ELECTRON_NODE_VERSION=`node -e "console.log(require('./package.json').engines.node)"`

if [[ "v$ELECTRON_NODE_VERSION" != "`node -v`" ]]; then
  echo "Incompatible NodeJS version. Expected: $ELECTRON_NODE_VERSION" 1>&2
  exit 1
fi

function install {
  rm -rf node_modules bower_components
  npm install --build-from-source
  bower install --production
}

function package {
  output_directory=$1

  $ELECTRON_PACKAGER . $APPLICATION_NAME \
    --platform=darwin \
    --arch=x64 \
    --version=$ELECTRON_VERSION \
    --ignore="`node scripts/packageignore.js`" \
    --asar \
    --app-copyright="$APPLICATION_COPYRIGHT" \
    --app-version="$APPLICATION_VERSION" \
    --build-version="$APPLICATION_VERSION" \
    --helper-bundle-id="io.resin.etcher-helper" \
    --app-bundle-id="io.resin.etcher" \
    --app-category-type="public.app-category.developer-tools" \
    --icon="assets/icon.icns" \
    --overwrite \
    --out=$output_directory

  rm $output_directory/Etcher-darwin-x64/LICENSE
  rm $output_directory/Etcher-darwin-x64/LICENSES.chromium.html
  rm $output_directory/Etcher-darwin-x64/version
}

function sign {
  source_application=$1

  $ELECTRON_OSX_SIGN $source_application --platform darwin --verbose --identity "$SIGN_IDENTITY_OSX"
  codesign --verify --deep --display --verbose=4 $source_application
  spctl --ignore-cache --no-cache --assess --type execute --verbose=4 $source_application
}

function installer_zip {
  source_directory=$1
  output_directory=$2

  mkdir -p $output_directory
  sign $source_directory/$APPLICATION_NAME.app
  pushd $source_directory
  zip -r -9 Etcher-darwin-x64.zip $APPLICATION_NAME.app
  popd
  mv $source_directory/Etcher-darwin-x64.zip $output_directory
}

function installer_dmg {
  source_directory=$1
  output_directory=$2
  temporal_dmg=$source_directory.dmg
  volume_directory=/Volumes/$APPLICATION_NAME
  volume_app=$volume_directory/$APPLICATION_NAME.app

  # Make sure any previous DMG was unmounted
  hdiutil detach $volume_directory || true

  # Create temporal read-write DMG image
  rm -f $temporal_dmg
  hdiutil create \
    -srcfolder $source_directory \
    -volname "$APPLICATION_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size 600M $temporal_dmg

  # Mount temporal DMG image, so we can modify it
  hdiutil attach $temporal_dmg -readwrite -noverify

  # Wait for a bit to ensure the image is mounted
  sleep 2

  # Link to /Applications within the DMG
  pushd $volume_directory
  ln -s /Applications
  popd

  # Symlink MacOS/Etcher to MacOS/Electron since for some reason, the Electron
  # binary tries to be ran in some systems.
  # See https://github.com/Microsoft/vscode/issues/92
  cp -p $volume_app/Contents/MacOS/Etcher $volume_app/Contents/MacOS/Electron

  # Set the DMG icon image
  # Writing this hexadecimal buffer to the com.apple.FinderInfo
  # extended attribute does the trick.
  # See https://github.com/LinusU/node-appdmg/issues/14#issuecomment-29080500
  cp assets/icon.icns $volume_directory/.VolumeIcon.icns
  xattr -wx com.apple.FinderInfo \
    "0000000000000000040000000000000000000000000000000000000000000000" $volume_directory

  # Configure background image.
  # We use tiffutil to create a "Multirepresentation Tiff file".
  # This allows us to show the retina and non-retina image when appropriate.
  mkdir $volume_directory/.background
  tiffutil -cathidpicheck assets/osx/installer.png assets/osx/installer@2x.png \
    -out $volume_directory/.background/installer.tiff

  # This AppleScript performs the following tasks
  # - Set the window basic properties.
  # - Set the window size and position.
  # - Set the icon size.
  # - Arrange the icons.
  echo '
     tell application "Finder"
       tell disk "'${APPLICATION_NAME}'"
         open
         set current view of container window to icon view
         set toolbar visible of container window to false
         set statusbar visible of container window to false
         set the bounds of container window to {400, 100, 944, 530}
         set viewOptions to the icon view options of container window
         set arrangement of viewOptions to not arranged
         set icon size of viewOptions to 110
         set background picture of viewOptions to file ".background:installer.tiff"
         set position of item "'${APPLICATION_NAME}.app'" of container window to {140, 225}
         set position of item "Applications" of container window to {415, 225}
         close
         open
         update without registering applications
         delay 2
         close
       end tell
     end tell
  ' | osascript
  sync

  sign $volume_app

  # Unmount temporal DMG image.
  hdiutil detach $volume_directory

  # Convert temporal DMG image into a production-ready
  # compressed and read-only DMG image.
  mkdir -p $output_directory
  rm -f $output_directory/Etcher-darwin-x64.dmg
  hdiutil convert $temporal_dmg \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o $output_directory/Etcher-darwin-x64.dmg

  # Cleanup temporal DMG image.
  rm $temporal_dmg

}

install
package etcher-release
installer_dmg etcher-release/Etcher-darwin-x64 etcher-release/installers
installer_zip etcher-release/Etcher-darwin-x64 etcher-release/installers
