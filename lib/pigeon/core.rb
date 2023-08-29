# frozen_string_literal: true

begin
  require 'circuitbox'
  require 'datadog/statsd'
  require 'ddtrace'
  require 'ddtrace/auto_instrument'
  require 'http'
  require 'http-cookie'
  require 'mime/types'
  require 'net/http'
  require 'openssl'
  require 'securerandom'
  require 'stringio'
  require 'uri'
  require 'zlib'
rescue LoadError => e
  print "load error: #{e.message}"
end

module Pigeon
  VALID_OPTIONS   = %w[request_timeout request_open_timeout ssl_verify volume_threshold error_threshold time_window sleep_window retryable retry_threshold].freeze
  VALID_CALLBACKS = %w[CircuitBreakerOpen CircuitBreakerClose HttpSuccess HttpError RetrySuccess RetryFailure]

  DEFAULT_OPTIONS = {
    request_name:         'pigeon_default',
    request_timeout:      60,
    request_open_timeout: 0,
    ssl_verify:           true,
    volume_threshold:     10,
    error_threshold:      10,
    time_window:          10,
    sleep_window:         10,
    retryable:            true,
    retry_threshold:      3
  }
  DEFAULT_CALLBACKS = {
    CircuitBreakerOpen:  nil,
    CircuitBreakerClose: nil,
    HttpSuccess:         nil,
    HttpError:           nil,
    RetrySuccess:        nil,
    RetryFailure:        nil
  }

  class Client
    attr_writer :request_name, :options, :callbacks

    def initialize name, opts = {}, clbk = {}
      @options   = DEFAULT_OPTIONS
      @callbacks = DEFAULT_CALLBACKS

      @options['request_name'] = name

      opts.each do |k, v|
        raise Error::Argument, "unknown option #{k}" unless VALID_OPTIONS.include?(k.to_s)
        @options[k] = v
      end

      clbk.each do |k, v|
        raise Error::Argument, "unknown callback #{k}" unless VALID_CALLBACKS.include?(k.to_s)
        @callbacks[k] = v
      end

      if @options['retryable']
        Retryable.configure do |config|
          config.sleep = lambda { |n| 4**n }
        end
      end

      Datadog.configure do |c|
        c.env     = ENV['DD_ENV']
        c.service = ENV['DD_SERVICE']
        c.tracing.partial_flush.enabled = true
        c.profiling.enabled = false
        c.runtime_metrics.enabled = false
        c.runtime_metrics.statsd = Datadog::Statsd.new
        c.tracing.sampler = Datadog::Tracing::Sampling::PrioritySampler.new(
                              post_sampler: Datadog::Tracing::Sampling::RuleSampler.new(
                                              [Datadog::Tracing::Sampling::SimpleRule.new(service: ENV['DD_SERVICE'], sample_rate: 1.0)]
                              )
        )
      end
    end

    def get url, args = {}
      start = Time.now
      response = http(:get, url, args)
      Pigeon::Statsd.new(@options['request_name'] + '_latency', tags: [url]).capture(action: :histogram, count: (Time.now - start))

      response
    rescue => e
      @callbacks['HttpError']&.call(e)
    end

    def post url, args = {}
      start = Time.now
      response = http(:post, url, args)
      Pigeon::Statsd.new(@options['request_name'] + '_latency', tags: [url]).capture(action: :histogram, count: (Time.now - start))

      response
    rescue => e
      @callbacks['HttpError']&.call(e)
    end

    def put url, args = {}
      http(:put, url, args)
    rescue => e
      @callbacks['HttpError']&.call(e)
    end

    def delete url, args = {}
      http(:delete, url, args)
    rescue => e
      @callbacks['HttpError']&.call(e)
    end

    def http method, url, args = {}
      args.merge({
        read_timeout: @options['request_timeout'],
        open_timeout: @options['request_open_timeout'],
        ssl_verify:   @options['ssl_verify']
      })
      response = Pigeon::Http::Request.new(method, url, args).execute
      Pigeon::Statsd.new(@options['request_name'] + '_througput', tags: [url]).capture

      response
    end

    def circuit
      Circuitbox.circuit(@options['request_name'], exceptions: [HTTP::ConnectionError, HTTP::HeaderError, HTTP::RequestError, HTTP::ResponseError, HTTP::TimeoutError])
    end
  end

  class Error < StandardError; end
end
