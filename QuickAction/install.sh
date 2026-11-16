#!/bin/zsh
# master-reel をビルドし、Finder のクイックアクション「超解像」「超解像＋フレーム補間」を ~/Library/Services にインストールする。
# 既にインストールされていれば置き換える。

set -euo pipefail

cd "${0:A:h}/.."
swift build -c release

# QuickAction/Master Reel.workflow を雛形に、クイックアクションを1つインストールする（副作用）。
# メニュー名と、run-quick-action に渡すオプションだけを書き換える。
install_quick_action() {
    local name="$1" menu="$2" option="$3"
    local destination="$HOME/Library/Services/$name.workflow"
    rm -rf "$destination"
    cp -R "QuickAction/Master Reel.workflow" "$destination"
    cp .build/release/master-reel "$destination/Contents/Resources/"
    plutil -replace NSServices.0.NSMenuItem.default -string "$menu" "$destination/Contents/Info.plist"
    plutil -replace actions.0.action.ActionParameters.COMMAND_STRING \
        -string "\"$destination/Contents/Resources/run-quick-action\" $option \"\$@\"" \
        "$destination/Contents/document.wflow"
    print "インストールしました: $destination"
}

install_quick_action "Master Reel" "超解像" ""
install_quick_action "Master Reel Interpolate" "超解像＋フレーム補間" --interpolate
/System/Library/CoreServices/pbs -update
