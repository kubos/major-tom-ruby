require 'major_tom/client'
require 'thread'

module MajorTom
  class ThreadedClient
    MAX_INTER_THREAD_QUEUE_LENGTH = 1000

    attr_accessor :uri, :gateway_token, :default_fields, :logger, :client

    def initialize(uri:, gateway_token:, default_fields: {}, logger: nil)
      @uri = uri
      @gateway_token = gateway_token
      @default_fields = default_fields
      @logger = logger

      @semaphore = Mutex.new
      @telemetry = []
      @events = []
      @command_updates = []
    end

    def on_hello(&block)
      @hello_block = block
    end

    def on_command(&block)
      @command_block = block
    end

    def on_error(&block)
      @error_block = block
    end

    def on_rate_limit(&block)
      @rate_limit_block = block
    end

    def telemetry(entries)
      @semaphore.synchronize {
        @telemetry << entries
        if @telemetry.length > MAX_INTER_THREAD_QUEUE_LENGTH
          @telemetry.pop
          logger.warn "Oldest buffered telemetry discarded due to buffer reaching max size of #{MAX_INTER_THREAD_QUEUE_LENGTH}."
        end
      }
    end

    def events(entries)
      @semaphore.synchronize {
        @events << entries
        if @events.length > MAX_INTER_THREAD_QUEUE_LENGTH
          @events.pop
          logger.warn "Oldest buffered event discarded due to buffer reaching max size of #{MAX_INTER_THREAD_QUEUE_LENGTH}."
        end
      }
    end

    def command_update(command, options = {})
      @semaphore.synchronize {
        @command_updates << [command, options]
        if @command_updates.length > MAX_INTER_THREAD_QUEUE_LENGTH
          @command_updates.pop
          logger.warn "Oldest buffered command update discarded due to buffer reaching max size of #{MAX_INTER_THREAD_QUEUE_LENGTH}."
        end
      }
    end

    def join
      @thread && @thread.join
    end

    def connect!
      @thread = Thread.new do
        begin
          EM.run do
            EM.error_handler{ |e|
              logger.error "Error raised during event loop: #{e.message}\n#{e.backtrace.join("\n")}"
            }

            @client = MajorTom::Client.new(
              uri: uri,
              gateway_token: gateway_token,
              default_fields: default_fields,
              logger: logger
            )

            client.on_hello do |hello_message|
              @hello_block.call(hello_message) if @hello_block
            end

            client.on_command do |command|
              @command_block.call(command) if @command_block
            end

            client.on_error do |error|
              @error_block.call(error) if @error_block
            end

            client.on_rate_limit do |rate_limit|
              @rate_limit_block.call(rate_limit) if @rate_limit_block
            end

            client.connect!

            EM::add_periodic_timer(0.5) do
              @semaphore.synchronize {
                while (entries = @telemetry.pop)
                  client.telemetry(entries)
                end

                while (entries = @events.pop)
                  client.events(entries)
                end

                while (command_update = @command_updates.pop)
                  client.command_update(*command_update)
                end
              }
            end
          end
        rescue => e
          message = "Exception in MajorTom::ThreadedClient: #{e.message} - #{e.backtrace.join("\n")}"
          if logger
            logger.error(message)
          else
            STDERR.puts message
          end
        end
      end
    end
  end
end
