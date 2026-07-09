require "rails_helper"

RSpec.describe StorableString do
  # The UTF-8 bytes of "é", escaped rather than typed so every literal below
  # is unambiguous about the bytes it holds.
  let(:e_acute) { "\xC3\xA9" }

  describe ".valid?" do
    it "accepts a plain string inside the cap" do
      expect(described_class.valid?("W/\"abc\"", max: 255)).to be(true)
    end

    it "accepts a value exactly at the cap and refuses one character more" do
      expect(described_class.valid?("a" * 255, max: 255)).to be(true)
      expect(described_class.valid?("a" * 256, max: 255)).to be(false)
    end

    it "refuses a non-String" do
      expect(described_class.valid?(nil, max: 255)).to be(false)
      expect(described_class.valid?(42, max: 255)).to be(false)
    end

    it "refuses an empty string" do
      expect(described_class.valid?("", max: 255)).to be(false)
    end

    it "refuses a NUL" do
      expect(described_class.valid?("a#{described_class::NUL}b", max: 255)).to be(false)
    end

    it "refuses invalid UTF-8 already tagged UTF-8" do
      expect(described_class.valid?("a\xC3\x28b", max: 255)).to be(false)
    end

    # Why the predicate re-tags before judging: Net::HTTP hands every header
    # value back ASCII-8BIT, and *every* byte sequence is a valid binary
    # string. Asking such a value `valid_encoding?` answers a question the
    # text column never posed, and it answers "yes" (docs/DECISIONS.md D-025).
    describe "a binary-tagged value" do
      let(:binary) { "a\xC3\x28b".b }

      it "is bug-shaped: valid as binary, invalid as UTF-8" do
        expect(binary.encoding).to eq(Encoding::ASCII_8BIT)
        expect(binary.valid_encoding?).to be(true)
        expect(binary.dup.force_encoding(Encoding::UTF_8).valid_encoding?).to be(false)
      end

      it "is refused when its bytes are not valid UTF-8" do
        expect(described_class.valid?(binary, max: 255)).to be(false)
      end

      it "is accepted when its bytes are valid UTF-8" do
        expect(described_class.valid?("caf#{e_acute}".b, max: 255)).to be(true)
      end

      # The cap counts characters (D-020). Judged as binary, a five-character
      # value would measure ten bytes and be refused for the wrong reason.
      it "counts characters against the cap, not bytes" do
        expect(described_class.valid?((e_acute * 5).b, max: 5)).to be(true)
        expect(described_class.valid?((e_acute * 6).b, max: 5)).to be(false)
      end

      it "is refused when it carries a NUL among otherwise valid bytes" do
        expect(described_class.valid?("a#{described_class::NUL}b".b, max: 255)).to be(false)
      end
    end
  end

  describe ".utf8" do
    it "re-tags a binary string without touching its bytes" do
      binary = "caf#{e_acute}".b
      tagged = described_class.utf8(binary)

      expect(tagged.encoding).to eq(Encoding::UTF_8)
      expect(tagged.bytes).to eq(binary.bytes)
    end

    it "returns an already-UTF-8 string unchanged" do
      value = "caf#{e_acute}"

      expect(described_class.utf8(value)).to equal(value)
    end
  end
end
