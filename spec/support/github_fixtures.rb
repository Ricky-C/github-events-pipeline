# Loads the raw `curl -sS -i --http1.1` captures in spec/fixtures/github/
# (see docs/DECISIONS.md D-015) and splits them into WebMock `to_return`
# hashes, so specs replay real GitHub responses — real weak ETags, real
# rate-limit headers — byte-for-byte.
module GithubFixtures
  DIR = Rails.root.join("spec/fixtures/github")

  # curl stores the de-chunked body, so replaying the captured framing
  # headers would make Net::HTTP misread the stubbed response.
  DROPPED_HEADERS = %w[ transfer-encoding content-length connection ].freeze

  module_function

  # WebMock-ready: stub_request(...).to_return(GithubFixtures.response(:events_200))
  def response(name)
    parse(name).slice(:status, :headers, :body)
  end

  def header(name, field)
    parse(name)[:headers][field.downcase]
  end

  def json_body(name)
    JSON.parse(parse(name)[:body])
  end

  # The canonical PushEvent subset of a captured page. Specs select through
  # here so a re-captured fixture (D-015) changes one method, not every
  # call site.
  def push_events(name = :events_200)
    json_body(name).select { |event| event["type"] == "PushEvent" }
  end

  def first_push(name = :events_200)
    push_events(name).first
  end

  def parse(name)
    @cache ||= {}
    @cache[name] ||= begin
      head, body = DIR.join("#{name}.http").read.split(/\r?\n\r?\n/, 2)
      status_line, *header_lines = head.split(/\r?\n/)
      headers = header_lines.to_h { |line| key, value = line.split(": ", 2); [ key.downcase, value ] }
      {
        status: status_line[%r{\AHTTP/1\.1 (\d{3})}, 1].to_i,
        headers: headers.except(*DROPPED_HEADERS),
        body: body.to_s
      }
    end
  end
end
