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
      VALID_PARAMETERS        = %w[headers files query body auth timeout open_timeout ssl_timeout read_timeout max_redirects ssl_verify jar]
      DEFAULT_HEADERS         = { 'User-Agent' => 'HTTP Client API/1.0' }
      REDIRECT_WITH_GET       = [301, 302, 303]
      REDIRECT_WITH_ORIGINAL  = [307, 308]
      VALID_VERBS             = [GET, HEAD, PUT, POST, DELETE, OPTIONS, TRACE]
      VALID_SSL_VERIFICATIONS = [SSL_VERIFY_NONE, SSL_VERIFY_PEER]
      VALID_REDIRECT_CODES    = REDIRECT_WITH_GET + REDIRECT_WITH_ORIGINAL

      def initialize verb, uri, args = {}
        args.each do |k, v|
          raise Error::Argument, "unknown argument #{k}" unless VALID_PARAMETERS.include?(k.to_s)
        end

        uri       = parse_uri!(uri)
        @delegate = create_request_delegate(verb, uri, args)

        if (body = args[:body])
          raise Error::Argument, "#{verb} cannot have body" unless @delegate.class.const_get(:REQUEST_HAS_BODY)
          @delegate.body = body
        end

        if (auth = args[:auth])
          @delegate.basic_auth(auth.fetch(:username), auth.fetch(:password))
        end

        if uri.user && uri.password
          @delegate.basic_auth(uri.user, uri.password)
        end

        @open_timeout = Http.open_timeout
        @read_timeout = Http.read_timeout
        @ssl_timeout  = Http.ssl_timeout

        if (timeout = args[:timeout])
          @open_timeout = timeout
          @read_timeout = timeout
          @ssl_timeout  = timeout
        end

        @open_timeout = args[:open_timeout] if args[:open_timeout]
        @read_timeout = args[:read_timeout] if args[:read_timeout]
        @ssl_timeout  = args[:ssl_timeout]  if args[:ssl_timeout]

        @max_redirects = args.fetch(:max_redirects, 0)
        @ssl_verify    = args.fetch(:ssl_verify, SSL_VERIFY_PEER)
        @jar           = args.fetch(:jar, HTTP::CookieJar.new)
      end

      def execute
        last_effective_uri = uri

        cookie = HTTP::Cookie.cookie_value(@jar.cookies(uri))
        if cookie && !cookie.empty?
          @delegate.add_field('Cookie', cookie)
        end

        response = request!(uri, @delegate)
        @jar.parse(response['set-cookie'].to_s, uri)

        redirects = 0

        while redirects < @max_redirects && VALID_REDIRECT_CODES.include?(response.code.to_i)
          redirects         += 1
          last_effective_uri = parse_uri! response['location']
          redirect_delegate  = redirect_to(last_effective_uri, response.code.to_i)
          cookie             = HTTP::Cookie.cookie_value(@jar.cookies(last_effective_uri))

          if cookie && !cookie.empty?
            redirect_delegate.add_field('Cookie', cookie)
          end

          response = request!(last_effective_uri, redirect_delegate)
          @jar.parse(response['set-cookie'].to_s, last_effective_uri)
        end

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
            raise Error::URI, "Invalid URI #{uri}" if uri.host.nil?
            uri
          when URI::Generic
            if @delegate&.uri
              @delegate.uri.dup.tap { |s| s += uri }
            else
              raise Error::URI, "Invalid URI #{uri}"
            end
          else
            raise Error::URI, "Invalid URI #{uri}"
        end
      rescue URI::InvalidURIError => e
        raise Error::URI, "Invalid URI #{uri}"
      end

      def create_request_delegate verb, uri, args
        klass    = find_delegate_class(verb)
        headers  = DEFAULT_HEADERS.merge(args.fetch(:headers, {}))
        files    = args[:files]
        qs       = args[:query]
        uri      = uri.dup
        delegate = nil

        if files
          raise Error::Argument, "#{verb} cannot have body" unless klass.const_get(:REQUEST_HAS_BODY)
          multipart             = Multipart.new(files, qs)
          delegate              = klass.new(uri, headers)
          delegate.content_type = multipart.content_type
          delegate.body         = multipart.body
        elsif qs
          if klass.const_get(:REQUEST_HAS_BODY)
            delegate = klass.new(uri, headers)
            delegate.set_form_data(qs)
          else
            uri.query = URI.encode_www_form(qs)
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

      def redirect_to uri, code
        case code
          when *REDIRECT_WITH_GET
            GET.new(uri, {}).tap do |r|
              @delegate.each_header do |field, value|
                next if field.downcase == 'host'

                r[field] = value
              end
            end
          when *REDIRECT_WITH_ORIGINAL
            @delegate.class.new(uri, {}).tap do |r|
              @delegate.each_header do |field, value|
                next if field.downcase == 'host'
                r[field] = value
              end

              r.body = @delegate.body
            end
          else
            raise Error, "response #{code} should not result in redirection."
        end
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
            raise Error::Argument, "Invalid verb #{string}"
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

    class Multipart
      attr_reader :boundary

      EOL               = "\r\n"
      DEFAULT_MIME_TYPE = 'application/octet-stream'

      def initialize files, query = {}
        @files    = files
        @query    = query || {}
        @boundary = generate_boundary
      end

      def content_type
        "multipart/form-data; boundary=#{boundary}"
      end

      def body
        body      = ''.encode('ASCII-8BIT')
        separator = "--#{boundary}"

        if @query && !@query.empty?
          @query.each do |key, value|
            body << separator << EOL
            body << %(Content-Disposition: form-data; name="#{key}") << EOL
            body << EOL
            body << value
            body << EOL
          end
        end

        if @files && !@files.empty?
          @files.each do |name, handle|
            if handle.respond_to?(:read)
              path = handle.path
              data = io.read
            else
              path = handle
              data = IO.read(path)
            end

            filename = File.basename(path)
            mime     = mime_type(filename)

            body << separator << EOL
            body << %(Content-Disposition: form-data; name="#{name}"; filename="#{filename}") << EOL
            body << %(Content-Type: #{mime})              << EOL
            body << %(Content-Transfer-Encoding: binary)  << EOL
            body << %(Content-Length: #{data.bytesize})   << EOL
            body << EOL
            body << data
            body << EOL
          end
        end

        body << separator << '--' << EOL
        body
      end

      private

      def generate_boundary
        SecureRandom.random_bytes(16).unpack1('H*')
      end

      def mime_type filename
        MIME::Types.type_for(File.extname(filename)).first || DEFAULT_MIME_TYPE
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