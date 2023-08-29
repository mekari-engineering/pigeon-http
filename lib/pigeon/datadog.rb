# frozen_string_literal: true

module Pigeon
  class Datadog
    def initialize(name:, tags: [])
      @statsd = Datadog::Statsd.new(ENV['STATSD_HOST'], ENV['STATSD_PORT'], tags: ["environment:#{ENV['DD_ENV']}", "project:#{ENV['DD_SERVICE']}"])
      @name   = name
      @tags   = tags
    end

    def capture(action: :increment, count: 0)
      return unless %w[increment count histogram].include? action.to_s

      case action.to_s
      when 'increment'
        increment(tags: @tags)
      when 'count'
        count(count: count, tags: @tags)
      when 'histogram'
        histogram(count: count, tags: @tags)
      else
        raise "unknown action #{action}"
      end
    end

    private

    def increment(tags: [])
      @statsd.increment(@name, tags: tags)
      @statsd.flush(sync: true)
      @statsd.close
    end
  
    def count(count: 0, tags: [])
      @statsd.count(@name, count, tags: tags)
      @statsd.flush(sync: true)
      @statsd.close
    end
  
    def histogram(count: 0, tags: [])
      @statsd.histogram(@name, count, tags: tags)
      @statsd.flush(sync: true)
      @statsd.close
    end
  end
end
