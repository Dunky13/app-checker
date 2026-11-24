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

  # The script removes the API key of the AI lookup from the keychain. Exit status 44: there is none.
  zap script: {
        executable: "/bin/sh",
        args:       ["-c",
                     "/usr/bin/security delete-generic-password -s io.went.kanarie -a llm-api-key " \
                     ">/dev/null 2>&1 || [ $? -eq 44 ] || " \
                     "echo 'Kanarie: remove the keychain item io.went.kanarie (llm-api-key) by hand' >&2"],
      },
      trash:  [
        "~/Library/Application Support/Kanarie",
        "~/Library/Caches/io.went.kanarie",
        "~/Library/HTTPStorages/io.went.kanarie",
        "~/Library/Preferences/io.went.kanarie.plist",
        "~/Library/Saved Application State/io.went.kanarie.savedState",
      ]
end
