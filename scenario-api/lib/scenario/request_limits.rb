require 'stringio'
require 'json'

module Scenario
  # Run before Rails instrumentation/parameter parsing, including requests without Content-Length.
  class RequestLimits
    MAX_BODY = 16_384
    def initialize(app)
      @app = app
    end

    def call(env)
      length = env['CONTENT_LENGTH'].to_i
      return too_large if length > MAX_BODY || env.fetch('QUERY_STRING', '').bytesize > 2048
      input = env['rack.input']
      if input
        body = input.read(MAX_BODY + 1) || ''
        return too_large if body.bytesize > MAX_BODY
        env['rack.input'] = StringIO.new(body)
      end
      status, headers, response = @app.call(env)
      [status, headers.merge('cache-control' => 'no-store', 'x-content-type-options' => 'nosniff'), response]
    end

    private

    def too_large
      [413, { 'content-type' => 'application/json', 'cache-control' => 'no-store' }, [JSON.generate(error: { code: 'body_too_large', message: 'body too large' })]]
    end
  end
end
