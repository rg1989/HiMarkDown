# Homebrew Cask for HiMarkDown
#
# To publish:
#   1. Create a public repo named `homebrew-himarkdown` on your GitHub
#      account (the `homebrew-` prefix is required by `brew tap`).
#   2. Copy this file to `Casks/himarkdown.rb` in that repo.
#   3. Tag and push the first HiMarkDown release; the GitHub Actions
#      workflow in this repo (`.github/workflows/release.yml`) prints the
#      .dmg SHA256 — paste it into `sha256` below and commit.
#
# Users then install with:
#   brew tap rg1989/himarkdown
#   brew install --cask himarkdown
#
# Brew handles: download, checksum verification, quarantine removal,
# install to /Applications, and uninstallation.
#
cask "himarkdown" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_MANIFEST"

  url "https://github.com/rg1989/HiMarkDown/releases/download/v#{version}/HiMarkDown-#{version}.dmg",
      verified: "github.com/rg1989/HiMarkDown/"
  name "HiMarkDown"
  desc "Native macOS Markdown editor with HTML preview, outline and themed UI"
  homepage "https://github.com/rg1989/HiMarkDown"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "HiMarkDown.app"

  zap trash: [
    "~/Library/Containers/dev.himarkdown.HiMarkDown",
    "~/Library/Preferences/dev.himarkdown.HiMarkDown.plist",
  ]
end
