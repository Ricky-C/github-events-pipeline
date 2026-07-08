require "spec_helper"

# A raw NUL byte in source has twice corrupted editor/tool round-trips in
# this repo; NUL belongs in specs only as the "\u0000" escape sequence.
# Captured fixtures are exempt — they replay upstream bytes verbatim.
RSpec.describe "repository hygiene" do
  it "contains no raw NUL bytes outside spec/fixtures" do
    root = File.expand_path("..", __dir__)
    excluded = %r{\A(?:\.git|log|tmp|storage|vendor|node_modules|spec/fixtures)(?:/|\z)}
    offenders = Dir.glob("**/*", File::FNM_DOTMATCH, base: root)
      .reject { |path| path.match?(excluded) || File.directory?(File.join(root, path)) }
      .select { |path| File.binread(File.join(root, path)).include?("\x00") }

    expect(offenders).to be_empty
  end
end
