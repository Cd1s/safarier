cask "safarier" do
  version "1.4.1"

  on_arm do
    sha256 "f4d7c35b017becec3e005895e7bd7b9faba85e4c0b6620ed435e86963a6cbaab"

    url "https://github.com/Cd1s/safarier/releases/download/v#{version}/Safarier-v#{version}-macOS-arm64.zip"
  end
  on_intel do
    sha256 "6d28248831946ccc74f9dfdc3b675ebc667a4ab7d9644e72e2a07ff365875bc9"

    url "https://github.com/Cd1s/safarier/releases/download/v#{version}/Safarier-v#{version}-macOS-x86_64.zip"
  end

  name "Safarier"
  desc "Native Safari multi-environment browser with isolated profiles"
  homepage "https://github.com/Cd1s/safarier"

  livecheck do
    url "https://github.com/Cd1s/safarier/releases/latest"
    strategy :github_latest
  end

  # The app downloads and replaces itself from About → Check for Updates…
  auto_updates true
  depends_on macos: :sonoma

  app "Safarier.app"

  uninstall quit: "sh.safarier.app"

  zap trash: [
    "~/.agents/skills/safarier-browser",
    "~/.claude-ifrr/skills/safarier-browser",
    "~/.claude/skills/safarier-browser",
    "~/Library/Application Support/Safarier",
    "~/Library/Caches/sh.safarier.app",
    "~/Library/Cookies/sh.safarier.app.binarycookies",
    "~/Library/HTTPStorages/sh.safarier.app",
    "~/Library/Preferences/sh.safarier.app.plist",
    "~/Library/Saved Application State/sh.safarier.app.savedState",
    "~/Library/WebKit/sh.safarier.app",
  ]

  caveats <<~EOS
    Safarier is ad-hoc signed and not notarized by Apple, so macOS asks for
    confirmation on first launch. If macOS only shows "Open Anyway" in
    System Settings → Privacy & Security, approve it there and open the app again.

    Update with the app's own About → Check for Updates…, or run:
      brew upgrade --cask safarier
  EOS
end
