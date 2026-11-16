#!/bin/zsh
# master-reel をビルドし、Finder のクイックアクション「超解像」として ~/Library/Services にインストールする。
# 既にインストールされていれば置き換える。

set -euo pipefail

cd "${0:A:h}/.."
swift build -c release

readonly destination="$HOME/Library/Services/Master Reel.workflow"
rm -rf "$destination"
cp -R "QuickAction/Master Reel.workflow" "$destination"
cp .build/release/master-reel "$destination/Contents/Resources/"
/System/Library/CoreServices/pbs -update

print "インストールしました: $destination"
