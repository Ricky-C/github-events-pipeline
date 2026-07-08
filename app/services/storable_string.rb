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

  # valid_encoding? runs before include?: several String methods raise
  # ArgumentError on invalid UTF-8, so nothing else may touch the value
  # until the encoding is known good.
  def self.valid?(value, max:)
    value.is_a?(String) && !value.empty? && value.length <= max &&
      value.valid_encoding? && !value.include?(NUL)
  end
end
