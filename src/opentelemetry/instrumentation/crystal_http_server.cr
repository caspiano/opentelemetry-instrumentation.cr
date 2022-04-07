require "./instrument"
require "tracer"
require "defined"

if_defined?("HTTP::Server") do
  module OpenTelemetry::Instrumentation
    class CrystalHttpServer < OpenTelemetry::Instrumentation::Instrument
    end
  end

  if_version?("Crystal", :>=, "1.0.0") do
    class HTTP::Request
      def scheme
        if uri = @uri
          uri.scheme.to_s
        else
          ""
        end
      end
    end

    class HTTP::Server
      # This should actually work back to Crystal 0.18.0, but the rest of this code probably won't,
      # so I am arbitrarily setting the bottom limit at Crystal 1.0.0. It may work on the 0.3x
      # versions, but this is entirely untested.
      # Wrap the start of request handling, the call to handle_client, in top-level-instrumentation.
      trace("handle_client") do
        trace = OpenTelemetry.trace
        trace.in_span("HTTP::Server connection") do |span|
          span.kind = OpenTelemetry::Span::Kind::Server
          local_addr = io.as(TCPSocket).local_address
          remote_addr = io.as(TCPSocket).remote_address
          span["net.peer.ip"] = remote_addr.address
          span["net.peer.port"] = remote_addr.port
          # Without parsing the request, we do not yet know the hostname, so the span will be started
          # with what is known, the IP, and the actual hostname can be backfilled later, after it is
          # parsed.
          span["http.host"] = local_addr.address
          previous_def
        end
      end

      # If the RequestProcessor were refactored a little bit, this could be much cleaner.
      class RequestProcessor
        # ameba:disable Metrics/CyclomaticComplexity
        def process(input, output)
          response = Response.new(output)

          begin
            until @wants_close
              request = HTTP::Request.from_io(
                input,
                max_request_line_size: max_request_line_size,
                max_headers_size: max_headers_size,
              )

              # EOF
              break unless request

              response.reset

              span = OpenTelemetry::Trace.current_span
              if request.is_a?(HTTP::Status)
                if span
                  span["http.status_code"] = request.code
                  span.add_event("Malformed Request or Error") do |event|
                    event["http.status_code"] = request.code
                  end
                end
                response.respond_with_status(request)
                return
              end

              response.version = request.version
              response.headers["Connection"] = "keep-alive" if request.keep_alive?
              context = Context.new(request, response)

              if span
                span["http.host"] = request.hostname.to_s
                span["http.method"] = request.method
                span["http.flavor"] = request.version.split("/").last
                span["http.scheme"] = request.scheme
                if content_length = request.content_length
                  span["http.response_content_length"] = content_length
                end
              end

              Log.with_context do
                @handler.call(context)
              rescue ex : ClientError
                Log.debug(exception: ex.cause) { ex.message }
              rescue ex
                Log.error(exception: ex) { "Unhandled exception on HTTP::Handler" }
                unless response.closed?
                  unless response.wrote_headers?
                    response.respond_with_status(:internal_server_error)
                  end
                end
                return
              ensure
                response.output.close
              end

              output.flush

              # If there is an upgrade handler, hand over
              # the connection to it and return
              if upgrade_handler = response.upgrade_handler
                upgrade_handler.call(output)
                return
              end

              break unless request.keep_alive?

              # Don't continue if the handler set `Connection` header to `close`
              break unless HTTP.keep_alive?(response)

              # The request body is either FixedLengthContent or ChunkedContent.
              # In case it has not entirely been consumed by the handler, the connection is
              # closed the connection even if keep alive was requested.
              case body = request.body
              when FixedLengthContent
                if body.read_remaining > 0
                  # Close the connection if there are bytes remaining
                  break
                end
              when ChunkedContent
                # Close the connection if the IO has still bytes to read.
                break unless body.closed?
              end
            end
          rescue IO::Error
            # IO-related error, nothing to do
          end
        end
      end
    end
  end
end
