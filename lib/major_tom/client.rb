require 'faye/websocket'
require 'eventmachine'
require 'json'
require_relative 'command'

module MajorTom
  class Client
    MAX_QUEUE_LENGTH = 1000

    attr_reader :host, :gateway_token, :default_fields, :tls, :logger, :ws, :connected

    # host: 'wss://your.majortom.host/'
    # gateway_token: '1234567890abcdefg'
    # tls:
    #   private_key_file: '/tmp/server.key',
    #   cert_chain_file: '/tmp/server.crt',
    #   verify_peer: false
    # logger: Logger.new(STDOUT)
    def initialize(host:, gateway_token:, default_fields: {}, tls: {}, logger: nil)
      @host = host
      @gateway_token = gateway_token
      @default_fields = default_fields
      @tls = tls
      @logger = logger
      @queue = []
      @connected = false
      @connect_started_at = nil
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

    def command_status(command, options = {})
      status = {
        "id" => command.id,
        "source" => options[:source] || options["source"] || "gateway"
      }

      if (errors = options["errors"] || options[:errors])
        status["errors"] = errors
      end

      if (code = options["code"] || options[:code])
        status["code"] = code
      end

      if (output = options["output"] || options[:output])
        status["output"] = output
      end

      if (payload = options["payload"] || options[:payload])
        status["payload"] = payload
      end

      transmit({
        "type" => "command_status",
        "command_status" => status
      })
    end

    def telemetry(entries)
      measurements = entries.map do |entry|
        {
          system: entry["system"] || entry[:system] || default_fields["system"] || default_fields[:system],
          subsystem: entry["subsystem"] || entry[:subsystem] || default_fields["subsystem"] || default_fields[:subsystem],
          metric: entry["metric"] || entry[:metric] || default_fields["metric"] || default_fields[:metric],
          value: entry["value"] || entry[:value],

          # Timestamp is expected to be millisecond unix epoch
          timestamp: ((entry["timestamp"] || entry[:timestamp]).to_f * 1000).to_i
        }
      end

      transmit({
        type: "measurements",
        measurements: measurements
      })
    end

    def log_messages(messages)
      log_messages = messages.map do |entry|
        {
          system: entry["system"] || entry[:system] || default_fields["system"] || default_fields[:system],
          level: entry["level"] || entry[:level] || default_fields["level"] || default_fields[:level],
          message: entry["message"] || entry[:message],

          # Timestamp is expected to be millisecond unix epoch
          timestamp: ((entry["timestamp"] || entry[:timestamp]).to_f * 1000).to_i
        }
      end

      transmit({
        type: "log_messages",
        log_messages: log_messages
      })
    end

    def connect!
      # connect_timer = EventMachine.add_timer 30, proc {
      #   if @ws && @ws.ready_state == Faye::WebSocket::Client::CONNECTING || @ws.ready_state == Faye::WebSocket::Client::CLOSED
      #     p(@ws, @ws.status, @ws.ready_state)
      #   end
      # }

      @ws = Faye::WebSocket::Client.new(host, nil, ping: 20, tls: tls, headers: {
        "X-Gateway-Token" => gateway_token
      })

      ws.on :open do |event|
        @connected = true
        logger.debug("Connected") if logger
      end

      ws.on :message do |event|
        logger.debug("Got: #{event.data}") if logger

        message = JSON.parse(event.data)
        message_type = message["type"]
        if message_type == "command"
          command = Command.new(message["command"])
          logger.debug("Command: #{command}") if logger
          @command_block.call(command) if @command_block
        elsif message_type == "error"
          logger.warn("Error from Major Tom: #{message["error"]}") if logger
          @error_block.call(message["error"]) if @error_block
        elsif message_type == "hello"
          logger.debug("Major Tom says hello: #{message}") if logger
          empty_queue!
          @hello_block.call(message["hello"]) if @hello_block
        else
          logger.error("Unknown message type #{message_type} received from Major Tom: #{message}") if logger
        end
      end

      ws.on :close do |event|
        logger.warn("Closed - reconnecting in 5s") if logger
        @connected = false
        @ws = nil
        EventMachine.add_timer 5, proc { connect! }
      end

      ws.on :warn do |event|
        logger.error("WebSocket error: #{event.message}") if logger
      end
    end

    private

    def transmit(message)
      if ws && @connected
        logger.debug("Sending: #{message.to_json}") if logger
        ws.send(message.to_json)
      else
        @queue << message

        if @queue.length > MAX_QUEUE_LENGTH
          logger.warn("Queue maxed out at #{@queue.length > MAX_QUEUE_LENGTH} items") if logger
          @queue.pop
        end
      end
    end

    def empty_queue!
      logger.debug("Flushing #{@queue.length} queued item(s).") if !@queue.empty? && logger

      while !@queue.empty? && ws
        transmit(@queue.pop)
      end
    end
  end
end
