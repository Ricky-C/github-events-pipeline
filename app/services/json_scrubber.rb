# The D-018/D-021 answer to data PostgreSQL's jsonb can never store (NUL
# anywhere, invalid UTF-8 bytes), shared by ingest (raw event payloads) and
# enrichment (fetched actor/repo bodies): classify whether a persistence
# failure was the data's own fault, and scrub the copy for the one retry it
# earns. Callers stamp the "payload_scrubbed" marker so a scrubbed copy is
# never mistaken for an authentic one.
module JsonScrubber
  # Everything a single row's persistence can raise: PG refusals surface as
  # StatementInvalid, but a value jsonb cannot serialize (invalid UTF-8)
  # dies client-side as JSON::GeneratorError before PG ever sees it —
  # treating only the former as row-scoped cost a whole page (D-021).
  ROW_ERRORS = [ ActiveRecord::StatementInvalid, JSON::GeneratorError ].freeze

  module_function

  # Data-shaped: jsonb couldn't serialize the value client-side, or PG
  # refused the values themselves (SQLSTATE class 22 — NUL escapes, invalid
  # encoding, numeric overflow). Everything else — contention, connection
  # blips, unforeseen refusals — is not the row's fault and earns an
  # unmodified retry. Classifying by data-shape rather than enumerating
  # transients means a false payload_scrubbed marker can never be stamped
  # onto authentic data by an error a list missed (D-021).
  def data_shaped?(error)
    error.is_a?(JSON::GeneratorError) || error.cause.is_a?(PG::DataException)
  end

  # Strip what jsonb can never store — NUL anywhere, invalid UTF-8 bytes —
  # from every string, hash keys included. Fidelity is knowingly traded for
  # durability: the verbatim value was unstorable to begin with (D-018).
  # String#scrub must run before #delete, which raises on invalid encodings.
  def scrub_unstorable(value)
    case value
    when String then value.scrub.delete("\u0000")
    when Hash then value.to_h { |key, val| [ scrub_unstorable(key), scrub_unstorable(val) ] }
    when Array then value.map { |element| scrub_unstorable(element) }
    else value
    end
  end
end
