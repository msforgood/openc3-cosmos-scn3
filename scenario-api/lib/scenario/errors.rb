module Scenario
  class Error < StandardError
    attr_reader :code, :status
    def initialize(code, message = nil, status = 400)
      @code, @status = code, status
      super(message || code.tr('_', ' '))
    end
  end

  module Canonical
    def self.sort(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, sort(value.fetch(key))] }
      when Array then value.map { |item| sort(item) }
      else value
      end
    end

    def self.json(value)
      JSON.generate(sort(value))
    end

    def self.hash(value)
      Digest::SHA256.hexdigest(json(value))
    end
  end
end
