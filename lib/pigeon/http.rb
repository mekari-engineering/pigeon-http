# frozen_string_literal: true

module Pigeon
  module Http
    GET                     = Net::HTTP::Get
    HEAD                    = Net::HTTP::Head
    PUT                     = Net::HTTP::Put
    POST                    = Net::HTTP::Post
    DELETE                  = Net::HTTP::Delete
    OPTIONS                 = Net::HTTP::Options
    TRACE                   = Net::HTTP::Trace
    SSL_VERIFY_NONE         = OpenSSL::SSL::VERIFY_NONE
    SSL_VERIFY_PEER         = OpenSSL::SSL::VERIFY_PEER

    class << self
      attr_accessor :open_timeout, :ssl_timeout, :read_timeout, :so_linger
    end

    class Request
      VALID_PARAMETERS        = %w[headers query body auth timeout open_timeout ssl_timeout read_timeout max_redirects ssl_verify]
      DEFAULT_HEADERS         = { 'User-Agent' => 'HTTP Client API/1.0' }
      VALID_VERBS             = [GET, HEAD, PUT, POST, DELETE, OPTIONS, TRACE]
      VALID_SSL_VERIFICATIONS = [SSL_VERIFY_NONE, SSL_VERIFY_PEER]

      def initialize verb, uri, args = {}
        args.each do |k, v|
          raise Error::Argument, "unknown argument #{k}" unless VALID_PARAMETERS.include?(k.to_s)
        end

        uri       = parse_uri!(uri)
        @delegate = create_request_delegate(verb, uri, args)

        # set timeout
        @open_timeout = args[:open_timeout] if args[:open_timeout]
        @read_timeout = args[:read_timeout] if args[:read_timeout]
        @ssl_timeout  = args[:ssl_timeout]  if args[:ssl_timeout]
        @ssl_verify   = args.fetch(:ssl_verify, SSL_VERIFY_PEER)

        # handle json body
        if (body = args[:body])
          raise Error::Argument, "#{verb} cannot have body" unless @delegate.class.const_get(:REQUEST_HAS_BODY)
          @delegate.body = body
        end

        # handle basic auth
        if (auth = args[:auth])
          @delegate.basic_auth(auth.fetch(:username), auth.fetch(:password))
        end

        if uri.user && uri.password
          @delegate.basic_auth(uri.user, uri.password)
        end
      end

      def execute
        response = request!(uri, @delegate)
        Response.new(response, last_effective_uri)
      end

      private

      def uri
        @delegate.uri
      end

      def parse_uri! uri
        uri = uri.is_a?(URI) ? uri : URI.parse(uri)

        case uri
          when URI::HTTP, URI::HTTPS
            raise Error::URI, "invalid URI #{uri}" if uri.host.nil?
            uri
          when URI::Generic
            if @delegate&.uri
              @delegate.uri.dup.tap { |s| s += uri }
            else
              raise Error::URI, "invalid URI #{uri}"
            end
          else
            raise Error::URI, "invalid URI #{uri}"
        end
      rescue URI::InvalidURIError => e
        raise Error::URI, "invalid URI #{uri}"
      end

      def create_request_delegate verb, uri, args
        klass    = find_delegate_class(verb)
        headers  = DEFAULT_HEADERS.merge(args.fetch(:headers, {}))
        body     = args[:body]
        query    = args[:query]
        uri      = uri.dup
        delegate = klass.new(uri, headers)

        if body
          raise Error::Argument, "#{verb} cannot have body" unless klass.const_get(:REQUEST_HAS_BODY)
          delegate.content_type = 'application/json'
          delegate.body         = body.to_json
        elsif query
          if klass.const_get(:REQUEST_HAS_BODY)
            delegate = klass.new(uri, headers)
            delegate.set_form_data(query)
          else
            uri.query = URI.encode_www_form(query)
            delegate  = klass.new(uri, headers)
          end
        else
          delegate = klass.new(uri, headers)
        end

        delegate
      end

      def request! uri, delegate
        http = Net::HTTP.new(uri.host, uri.port, :ENV)

        if uri.scheme == 'https'
          http.use_ssl     = true
          http.verify_mode = @ssl_verify
        end

        http.open_timeout = @open_timeout if @open_timeout
        http.read_timeout = @read_timeout if @read_timeout
        http.ssl_timeout  = @ssl_timeout  if @ssl_timeout
        response          = http.request(delegate)

        http.finish if http.started?
        response
      rescue URI::Error => e
        raise Error::URI.new(e.message, e)
      rescue Zlib::Error => e
        raise Error::Zlib.new(e.message, e)
      rescue Timeout::Error => e
        raise Error::Timeout.new(e.message, e)
      rescue Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e
        raise Error::Transport.new(e.message, e)
      end

      def find_delegate_class verb
        if VALID_VERBS.include?(verb)
          verb
        else
          find_verb_class(verb.to_s)
        end
      end

      def find_verb_class string
        case string
          when /^get$/i     then GET
          when /^head$/i    then HEAD
          when /^put$/i     then PUT
          when /^post$/i    then POST
          when /^delete$/i  then DELETE
          else
            raise Error::Argument, "invalid verb #{string}"
        end
      end
    end

    class Response
      attr_reader :last_effective_uri, :response

      def initialize response, last_effective_uri
        @response           = response
        @last_effective_uri = last_effective_uri
      end

      def code
        response.code.to_i
      end

      def headers
        @headers ||= Hash[response.each_header.entries]
      end

      def body
        case headers['content-encoding'].to_s.downcase
          when 'gzip'
            gz = Zlib::GzipReader.new(StringIO.new(response.body))
            begin
              gz.read
            ensure
              gz.close
            end
          when 'deflate'
            Zlib.inflate(response.body)
          else
            response.body
        end
      end

      def inspect
        "#<#{self.class} @code=#{code} @last_effective_uri=#{last_effective_uri}>"
      end
    end

    class << self
      def get uri, args = {}
        Request.new(GET, uri, args).execute
      end

      def put uri, args = {}
        Request.new(PUT, uri, args).execute
      end

      def post uri, args = {}
        Request.new(POST, uri, args).execute
      end

      def delete uri, args = {}
        Request.new(DELETE, uri, args).execute
      end

      def options uri, args = {}
        Request.new(OPTIONS, uri, args).execute
      end

      def trace uri, args = {}
        Request.new(TRACE, uri, args).execute
      end
    end

    class Error < StandardError
      attr_reader :original_error

      def initialize message, original_error = nil
        @original_error = original_error
        super(message)
      end

      class URI < Error; end

      class Zlib < Error; end

      class Timeout < Error; end

      class Transport < Error; end

      class Argument < Error; end
    end
  end
end
