# frozen_string_literal: true
# A minimal HTTP/1.1 server for the local web UI: one request per connection, Connection: close, no TLS,
# no keep-alive, no chunked bodies. Parsing and response building are plain functions so tests can drive
# the application without sockets; Server owns the TCPServer loop.
require "socket"

module Pinky
  module HTTP
    MAX_HEADER_BYTES = 64 * 1024
    MAX_BODY_BYTES = 4 * 1024 * 1024

    class Request
      attr_reader :method, :path, :query, :headers, :body

      def initialize(method, path, query, headers, body)
        @method = method
        @path = path
        @query = query
        @headers = headers
        @body = body
      end

      # Form fields for application/x-www-form-urlencoded bodies.
      def form = HTTP.parse_query(@body)
      def header(name) = @headers[name.downcase]
    end

    class Response
      attr_reader :status, :headers, :body

      def initialize(status, body, content_type = "text/html; charset=utf-8", headers = {})
        @status = status
        @body = body
        @headers = { "content-type" => content_type }
        headers.each { |k, v| @headers[k.to_s.downcase] = v.to_s }
      end

      def self.html(body, status = 200) = new(status, body)
      def self.json(body, status = 200) = new(status, body, "application/json; charset=utf-8")
      def self.text(body, status = 200) = new(status, body, "text/plain; charset=utf-8")
      def self.redirect(location) = new(303, "", "text/plain; charset=utf-8", { "location" => location })
      def self.not_found(what = "not found") = text("#{what}\n", 404)

      def to_s
        out = +""
        out << "HTTP/1.1 #{status} #{HTTP.reason(status)}\r\n"
        @headers.each { |k, v| out << k << ": " << v << "\r\n" }
        out << "content-length: #{body.bytesize}\r\n"
        out << "connection: close\r\n\r\n"
        out << body
        out
      end
    end

    def self.reason(status)
      case status
      when 200 then "OK"
      when 303 then "See Other"
      when 400 then "Bad Request"
      when 404 then "Not Found"
      when 405 then "Method Not Allowed"
      when 413 then "Payload Too Large"
      else "Internal Server Error"
      end
    end

    # Parses the head of a request (request line and headers, up to and excluding the blank line).
    # Returns nil when malformed.
    def self.parse_head(head)
      lines = head.split("\r\n")
      request_line = lines.shift.to_s
      parts = request_line.split(" ")
      return nil unless parts.size == 3 && parts[2].start_with?("HTTP/1.")
      target = parts[1].to_s
      qpos = target.index("?")
      path = qpos ? target[0, qpos].to_s : target
      query = qpos ? parse_query(target[qpos + 1, target.size - qpos - 1].to_s) : {}
      headers = {}
      lines.each do |line|
        colon = line.index(":")
        next unless colon
        headers[line[0, colon].to_s.strip.downcase] = line[colon + 1, line.size - colon - 1].to_s.strip
      end
      Request.new(parts[0].to_s.upcase, unescape(path), query, headers, "")
    end

    def self.with_body(req, body) = Request.new(req.method, req.path, req.query, req.headers, body)

    # Whole request from one string (tests); the body is whatever follows the blank line.
    def self.parse(raw)
      sep = raw.index("\r\n\r\n")
      return nil unless sep
      req = parse_head(raw[0, sep].to_s)
      return nil unless req
      with_body(req, raw[sep + 4, raw.size - sep - 4].to_s)
    end

    def self.parse_query(text)
      out = {}
      text.to_s.split("&").each do |pair|
        next if pair.empty?
        eq = pair.index("=")
        key = eq ? pair[0, eq].to_s : pair
        value = eq ? pair[eq + 1, pair.size - eq - 1].to_s : ""
        out[unescape(key)] = unescape(value)
      end
      out
    end

    def self.unescape(text)
      s = text.to_s.tr("+", " ")
      return s unless s.include?("%")
      bytes = []
      i = 0
      while i < s.bytesize
        b = s.getbyte(i).to_i
        if b == 37 && i + 2 < s.bytesize + 0 && hex?(s.getbyte(i + 1).to_i) && hex?(s.getbyte(i + 2).to_i)
          bytes << (hexval(s.getbyte(i + 1).to_i) * 16 + hexval(s.getbyte(i + 2).to_i))
          i += 3
        else
          bytes << b
          i += 1
        end
      end
      bytes.pack("C*").force_encoding("UTF-8")
    end

    def self.escape(text)
      out = +""
      text.to_s.bytes.each do |b|
        if (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 45 || b == 46 || b == 95 || b == 126
          out << b.chr
        else
          out << "%" << (b < 16 ? "0" : "") << b.to_s(16).upcase
        end
      end
      out
    end

    def self.hex?(b) = (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)

    def self.hexval(b)
      return b - 48 if b <= 57
      return b - 55 if b <= 70
      b - 87
    end

    # Accepts connections forever and hands each request to app.call(request) -> Response.
    class Server
      def initialize(app, host, port)
        @app = app
        @host = host
        @port = port
      end

      def run(log = $stderr)
        server = TCPServer.new(@host, @port)
        log.puts "pinky web ui on http://#{@host}:#{@port}/"
        loop do
          sock = server.accept
          sock.sync = true
          serve_one(sock, log)
        end
      end

      def serve_one(sock, log)
        req = read_request(sock)
        response = if req.nil?
          Response.text("bad request\n", 400)
        else
          begin
            @app.call(req)
          rescue StandardError => e
            log.puts "pinky web: #{e.class}: #{e.message}"
            Response.text("internal error: #{e.message}\n", 500)
          end
        end
        sock.write(response.to_s)
        sock.close
        nil
      end

      # Header lines until the blank line, then exactly Content-Length body bytes (read loops because
      # IO#read may return short on sockets).
      def read_request(sock)
        head = +""
        while (line = sock.gets)
          break if line == "\r\n" || line == "\n"
          head << line
          return nil if head.bytesize > MAX_HEADER_BYTES
        end
        return nil if head.empty?
        req = HTTP.parse_head(head)
        return nil if req.nil?
        length = req.header("content-length").to_s.to_i
        return nil if length > MAX_BODY_BYTES
        body = +""
        while body.bytesize < length
          chunk = sock.read(length - body.bytesize)
          break if chunk.nil? || chunk.empty?
          body << chunk
        end
        HTTP.with_body(req, body)
      end
    end
  end
end
