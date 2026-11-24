# scripts/release.sh writes version and sha256 at every release.
cask "kanarie" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Dunky13/kanarie/releases/download/v#{version}/Kanarie-#{version}-universal.zip"
  name "Kanarie"
  desc "Shows which installed apps and tools send telemetry"
  homepage "https://github.com/Dunky13/kanarie"

  livecheck do
    url "https://raw.githubusercontent.com/Dunky13/kanarie/main/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sequoia

  app "Kanarie.app"

  uninstall quit: "io.went.kanarie"

  zap trash: [
    "~/Library/Application Support/Kanarie",
    "~/Library/Caches/io.went.kanarie",
    "~/Library/HTTPStorages/io.went.kanarie",
    "~/Library/Preferences/io.went.kanarie.plist",
  ]
end
