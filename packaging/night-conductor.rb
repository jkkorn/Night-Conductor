# Homebrew Cask for Night Conductor.
#
# To publish: create a tap repo at github.com/jkkorn/homebrew-tap and put this
# file at Casks/night-conductor.rb. Users then run:
#   brew install --cask jkkorn/tap/night-conductor
# On each release, bump `version` and `sha256` (shasum -a 256 <zip>). Ad-hoc
# codesign is not reproducible, so re-running build-app.sh on identical source
# still changes the sha256, so always take it from the exact zip you upload as
# the release asset, not an earlier build.
# Until the app is notarized, installs should add --no-quarantine (see caveats).
cask "night-conductor" do
  version "1.0.12"
  sha256 "d2f6200c0f28fe73dcae3a39f96f683ae32bc0d6d0d4b4bb86d533e02f80c877"

  url "https://github.com/jkkorn/Night-Conductor/releases/download/v#{version}/Night-Conductor-#{version}.zip"
  name "Night Conductor"
  desc "Resume Conductor sessions that hit the Claude usage limit, while you sleep"
  homepage "https://github.com/jkkorn/Night-Conductor"

  depends_on macos: ">= :sequoia"
  app "Night Conductor.app"

  caveats <<~EOS
    The prebuilt app is not notarized yet, so macOS blocks the first launch.
    Either install with:
      brew install --cask --no-quarantine jkkorn/tap/night-conductor
    or clear the quarantine once:
      xattr -dr com.apple.quarantine "/Applications/Night Conductor.app"
  EOS

  zap trash: [
    "~/Library/Preferences/app.night-conductor.plist",
    "~/Library/LaunchAgents/com.autoconduct.agent.plist",
  ]
end
