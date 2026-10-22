#!/bin/zsh
# Makes a release anyone can download: builds and signs ScreenVibe.app with the Developer ID, has Apple notarize it,
# staples the ticket, zips it, publishes it as a GitHub Release, and updates the Homebrew cask in ScreenVibe/homebrew-tap.
# Needs: a Developer ID certificate, `xcrun notarytool store-credentials screenvibe-notary` done once, and gh signed in.
# Version: the VERSION file. Raise it before running.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
TAG="v$VERSION"
OUT="${TMPDIR:-/tmp}/screenvibe-release"   # not under Documents: a synced folder adds file info codesign refuses
APP="$OUT/ScreenVibe.app"
ZIP="$OUT/ScreenVibe-$VERSION.zip"

[[ -n "$(git status --porcelain)" ]] && { echo "Commit your changes first."; exit 1; }
gh release view "$TAG" >/dev/null 2>&1 && { echo "$TAG is already released. Raise VERSION."; exit 1; }

rm -rf "$OUT"
APP="$APP" RELEASE=1 ./build.sh

# Apple wants a zip to check; the ticket then goes into the app, and the stapled app is zipped again for people.
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile screenvibe-notary --wait
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "ScreenVibe $VERSION" --notes "Download ScreenVibe-$VERSION.zip, unzip it, and move ScreenVibe to Applications. Or: brew install --cask ScreenVibe/tap/screenvibe"

# The cask: the recipe brew reads. Kept in its own repo, which brew calls a tap.
TAP="$OUT/homebrew-tap"
gh repo clone ScreenVibe/homebrew-tap "$TAP" -- -q
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/screenvibe.rb" <<CASK
cask "screenvibe" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/ScreenVibe/ScreenVibe/releases/download/v#{version}/ScreenVibe-#{version}.zip"
  name "ScreenVibe"
  desc "Mark up your screen and send it straight to Claude Code"
  homepage "https://github.com/ScreenVibe/ScreenVibe"

  depends_on macos: ">= :sonoma"

  app "ScreenVibe.app"

  zap trash: "~/.screenvibe"

  caveats <<~EOS
    Add the Claude Code add-on:
      claude plugin marketplace add ScreenVibe/ScreenVibe
      claude plugin install screenvibe@screenvibe
  EOS
end
CASK
git -C "$TAP" add -A
git -C "$TAP" commit -qm "ScreenVibe $VERSION"
git -C "$TAP" push -q
echo "Released $TAG: $(gh release view "$TAG" --json url --jq .url)"
