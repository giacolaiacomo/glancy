class Glancy < Formula
  desc "Notch app for macOS: Claude Code agents, calendar, media, clipboard and windows"
  homepage "https://github.com/giacolaiacomo/glancy"
  url "https://github.com/giacolaiacomo/glancy/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on "cmake" => :build
  depends_on macos: :sonoma

  def install
    # Built from source on your Mac with Swift 6.2 (Xcode 26 or its Command Line Tools).
    # Signed with your Apple Development certificate if you have one, otherwise ad-hoc.
    ENV["GLANCY_VERSION"] = version.to_s
    system "./scripts/build-app.sh", prefix/"Glancy.app"
    bin.install_symlink prefix/"Glancy.app/Contents/MacOS/Glancy" => "glancy"
  end

  service do
    run [opt_prefix/"Glancy.app/Contents/MacOS/Glancy"]
    keep_alive successful_exit: false
    process_type :interactive
  end

  def caveats
    <<~EOS
      Start Glancy now and at every login:
        brew services start glancy
      Every permission is optional; the first launch shows a checklist in the notch.
      For the Claude Code agents, add the hook described in the README:
        https://github.com/giacolaiacomo/glancy#claude-code-setup
    EOS
  end

  test do
    # Headless: every module on throwaway state, no window, no permission prompt. Run from inside
    # the bundle so the bundled now-playing helper and icon are checked too.
    system prefix/"Glancy.app/Contents/MacOS/Glancy", "--self-test"
  end
end
