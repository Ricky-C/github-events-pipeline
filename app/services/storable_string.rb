# The one storable-string predicate for payload-derived text
# (docs/THREAT-MODEL.md length validation; D-018, D-020, D-021): a string
# may reach a text column only if it is a non-empty String within the cap,
# valid UTF-8, and NUL-free. PG refuses invalid encoding and NUL outright,
# and "fixing" an identifying string would store a forged one, so
# unstorable means reject. Caps count characters (bytes are bounded at 4x).
# Both the raw event id and every structured field go through here, so the
# policy cannot drift between the two layers.
module StorableString
  NUL = "\u0000"

  # The question is always "can these bytes live in a UTF-8 column", never
  # "what does this String think it is". Net::HTTP tags header values
  # ASCII-8BIT, and `valid_encoding?` is vacuously true of every byte
  # sequence under that tag — so judging the tag would wave through exactly
  # the bytes PG rejects, and count them as bytes rather than characters
  # (docs/DECISIONS.md D-025). Judge a UTF-8-tagged view instead.
  #
  # valid_encoding? runs before include?: several String methods raise
  # ArgumentError on invalid UTF-8, so nothing else may touch the value
  # until the encoding is known good.
  def self.valid?(value, max:)
    return false unless value.is_a?(String)

    text = utf8(value)
    !text.empty? && text.length <= max && text.valid_encoding? && !text.include?(NUL)
  end

  # The same re-tagging, for callers that must emit the value they validated
  # rather than the binary original — one copy of the normalization, so it
  # cannot drift from the predicate that depends on it.
  def self.utf8(value)
    return value if value.encoding == Encoding::UTF_8

    value.dup.force_encoding(Encoding::UTF_8)
  end
end
