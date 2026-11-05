cask "safarier" do
  version "1.3.0"

  on_arm do
    sha256 "09581f0f3eb7f54351221008692bc8717312e96b75da0bad1f591037a48f3ac2"

    url "https://github.com/Cd1s/safarier/releases/download/v#{version}/Safarier-v#{version}-macOS-arm64.zip"
  end
  on_intel do
    sha256 "74dde9933d1ea29de0b0de2b4c21cfc17fb0d3f796d5b42b05053a522b164674"

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
