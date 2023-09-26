# frozen_string_literal: true

begin
  require 'circuitbox'
  require 'datadog/statsd'
  require 'http'
  require 'http-cookie'
  require 'mime/types'
  require 'net/http'
  require 'openssl'
  require 'retryable'
  require 'securerandom'
  require 'stringio'
  require 'uri'
  require 'zlib'
rescue LoadError => e
  print "load error: #{e.message}"
end

module Pigeon
  VALID_OPTIONS   = %w[environment request_timeout request_open_timeout ssl_verify volume_threshold error_threshold time_window sleep_window retryable retry_threshold monitoring monitoring_type].freeze
  VALID_CALLBACKS = %w[CircuitBreakerOpen CircuitBreakerClose HttpSuccess HttpError RetrySuccess RetryFailure]

  DEFAULT_OPTIONS = {
    environment:          'default',
    request_name:         'pigeon_default',
    request_timeout:      60,
    request_open_timeout: 0,
    ssl_verify:           true,
    volume_threshold:     10,
    error_threshold:      10,
    time_window:          10,
    sleep_window:         10,
    retryable:            true,
    retry_threshold:      3,
    monitoring:           false,
    monitoring_type:      'datadog'
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

      @options[:request_name] = name

      opts.each do |k, v|
        raise Error::Argument, "unknown option #{k}" unless VALID_OPTIONS.include?(k.to_s)
        @options[k.to_sym] = v
      end

      clbk.each do |k, v|
        raise Error::Argument, "unknown callback #{k}" unless VALID_CALLBACKS.include?(k.to_s)
        @callbacks[k.to_sym] = v
      end

      if @options[:retryable]
        Retryable.configure do |config|
          config.sleep = lambda { |n| 4**n }
        end
      end
    end

    def config key, value
      raise Error::Argument, "unknown option #{key}" unless VALID_OPTIONS.include?(key.to_s)
      @options[key.to_sym] = value
    end

    def get url, args = {}
      response = http(:get, url, args)
    rescue => e
      @callbacks[:HttpError]&.call(e)
    end

    def post url, args = {}
      response = http(:post, url, args)
    rescue => e
      @callbacks[:HttpError]&.call(e)
    end

    def put url, args = {}
      response = http(:put, url, args)
    rescue => e
      @callbacks[:HttpError]&.call(e)
    end

    def delete url, args = {}
      response = http(:delete, url, args)
    rescue => e
      @callbacks[:HttpError]&.call(e)
    end

    def http method, url, args = {}
      start = Time.now
      args.merge({
        read_timeout: @options[:request_timeout],
        open_timeout: @options[:request_open_timeout],
        ssl_verify:   @options[:ssl_verify]
      })
      response = Pigeon::Http::Request.new(method, url, args).execute

      uri = URI.parse(url)
      Pigeon::Statsd.new(@options[:request_name] + '_latency', tags: [uri.host]).capture(action: :histogram, count: (Time.now - start))
      Pigeon::Statsd.new(@options[:request_name] + '_througput', tags: [uri.host]).capture
      Pigeon::Statsd.new(@options[:request_name] + '_status', tags: [response.code]).capture

      response
    end

    def circuit
      Circuitbox.circuit(@options[:request_name], exceptions: [HTTP::ConnectionError, HTTP::HeaderError, HTTP::RequestError, HTTP::ResponseError, HTTP::TimeoutError])
    end
  end

  class Error < StandardError; end
end
