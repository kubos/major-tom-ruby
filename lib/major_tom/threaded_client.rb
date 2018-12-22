require 'major_tom/client'
require 'thread'

module MajorTom
  class ThreadedClient
    MAX_INTER_THREAD_QUEUE_LENGTH = 1000

    attr_accessor :host, :gateway_token, :default_fields, :logger, :client

    def initialize(host:, gateway_token:, default_fields: {}, logger: nil)
      @host = host
      @gateway_token = gateway_token
      @default_fields = default_fields
      @logger = logger

      @semaphore = Mutex.new
      @telemetry = []
      @log_messages = []
      @command_statuses = []
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

    def telemetry(entries)
      @semaphore.synchronize {
        @telemetry << entries
        @telemetry.pop if @telemetry.length > MAX_INTER_THREAD_QUEUE_LENGTH
      }
    end

    def log_messages(entries)
      @semaphore.synchronize {
        @log_messages << entries
        @log_messages.pop if @log_messages.length > MAX_INTER_THREAD_QUEUE_LENGTH
      }
    end

    def command_status(command, options = {})
      @semaphore.synchronize {
        @command_statuses << [command, options]
        @command_statuses.pop if @command_statuses.length > MAX_INTER_THREAD_QUEUE_LENGTH
      }
    end

    def join
      @thread && @thread.join
    end

    def connect!
      @thread = Thread.new do
        begin
          EM.run do
            @client = MajorTom::Client.new(
              host: host,
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

            client.connect!

            EM::add_periodic_timer(0.5) do
              @semaphore.synchronize {
                while (entries = @telemetry.pop)
                  client.telemetry(entries)
                end

                while (entries = @log_messages.pop)
                  client.log_messages(entries)
                end

                while (command_status = @command_statuses.pop)
                  client.command_status(*command_status)
                end
              }
            end
          end
        rescue => e
          puts "Exception in MajorTom::ThreadedClient: #{e.message} - #{e.backtrace.join("\n")}"
        end
      end
    end
  end
end
