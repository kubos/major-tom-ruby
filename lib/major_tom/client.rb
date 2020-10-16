require 'faye/websocket'
require 'eventmachine'
require 'json'
require 'base64'
require_relative 'command'

module MajorTom
  class Client
    MAX_QUEUE_LENGTH = 10_000

    attr_reader :uri, :gateway_token, :default_fields, :tls, :basic_auth, :logger, :connected

    # uri: 'wss://your.majortom.host/gateway_api/v1.0'
    # gateway_token: '1234567890abcdefg'
    # tls:
    #   private_key_file: '/tmp/server.key',
    #   cert_chain_file: '/tmp/server.crt',
    #   verify_peer: false
    # logger: Logger.new(STDOUT)
    def initialize(uri:, gateway_token:, default_fields: {}, tls: {}, basic_auth: nil, logger: Logger.new(STDOUT))
      @uri = uri
      @gateway_token = gateway_token
      @default_fields = default_fields
      @tls = tls
      @basic_auth = basic_auth
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

    def on_rate_limit(&block)
      @rate_limit_block = block
    end

    def on_transit(&block)
      @transit_block = block
    end

    def command_update(command, options = {})
      command_info = {
        "id" => command.id
      }

      %w[state payload status output errors
         progress_1_current progress_1_max progress_1_label
         progress_2_current progress_2_max progress_2_label].each do |field|
        if (value = options[field] || options[field.to_sym])
          command_info[field] = value
        end
      end

      transmit({
        "type" => "command_update",
        "command" => command_info
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
          timestamp: ((entry["timestamp"] || entry[:timestamp] || Time.now).to_f * 1000).to_i
        }
      end

      transmit({
        type: "measurements",
        measurements: measurements
      })
    end

    def events(messages)
      events = messages.map do |entry|
        {
          system: entry["system"] || entry[:system] || default_fields["system"] || default_fields[:system],
          type: entry["type"] || entry[:type] || default_fields["type"] || default_fields[:type],
          message: entry["message"] || entry[:message],
          level: entry["level"] || entry[:level] || default_fields["level"] || default_fields[:level],
          command_id: entry["command_id"] || entry[:command_id],
          debug: entry["debug"] || entry[:debug],

          # Timestamp is expected to be millisecond unix epoch
          timestamp: ((entry["timestamp"] || entry[:timestamp] || Time.now).to_f * 1000).to_i
        }
      end

      transmit({
        type: "events",
        events: events
      })
    end

    def disconnect!
      @ping_timer.cancel if @ping_timer
      @ping_timeout_timer.cancel if @ping_timeout_timer
      @ws.close if @ws
      @connected = false
    end

    def connect!
      logger.info("Connecting to #{uri}") if logger

      headers = { "X-Gateway-Token" => gateway_token }
      if basic_auth
        headers["Authorization"] = "Basic #{Base64.strict_encode64(basic_auth)}"
      end
      @ws = Faye::WebSocket::Client.new(uri, nil, tls: tls, headers: headers)

      @ws.on :open do |event|
        @connected = true
        logger.info("Connected") if logger

        # Setup ping
        @ping_timer.cancel if @ping_timer
        @ping_timeout_timer.cancel if @ping_timeout_timer
        @ping_timer = EventMachine::PeriodicTimer.new(10) do
          @ping_timeout_timer = EventMachine::Timer.new(2) do
            logger.warn("Ping timeout exceeded. Disconnecting...") if logger
            @ping_timer.cancel if @ping_timer
            @ws.close if @ws
          end

          logger.debug("Pinging") if logger
          @ws.ping 'detecting presence' do
            logger.debug("Ping received.") if logger
            @ping_timeout_timer.cancel if @ping_timeout_timer
          end
        end
      end

      @ws.on :message do |event|
        logger.debug("Got: #{event.data}") if logger

        message = JSON.parse(event.data)
        message_type = message["type"]
        if message_type == "command"
          command = Command.new(message["command"])
          logger.info("Command: #{command}") if logger
          @command_block.call(command) if @command_block
        elsif message_type == "error"
          logger.warn("Error from Major Tom: #{message["error"]}") if logger
          @error_block.call(message["error"]) if @error_block
        elsif message_type == "rate_limit"
          logger.warn("Rate limit from Major Tom: #{message["rate_limit"]}") if logger
          @rate_limit_block.call(message["rate_limit"]) if @rate_limit_block
        elsif message_type == "transit"
          logger.info("Transit advistory from Major Tom: #{message["transit"]}") if logger
          @transit_block.call(message["transit"]) if @transit_block
        elsif message_type == "hello"
          logger.info("Major Tom says hello: #{message}") if logger
          empty_queue!
          @hello_block.call(message["hello"]) if @hello_block
        else
          logger.error("Unknown message type #{message_type} received from Major Tom: #{message}") if logger
        end
      end

      @ws.on :close do |event|
        logger.warn("Connection closed") if logger
        @connected = false
        @ping_timer.cancel if @ping_timer
        @ping_timeout_timer.cancel if @ping_timeout_timer
        @reconnect_timer.cancel if @reconnect_timer
        @ws = nil

        # logger.warn("Reconnecting in 30s") if logger
        # @reconnect_timer = EventMachine::Timer.new(30) do
        #   connect! unless @connected
        # end
      end

      @ws.on :error do |event|
        logger.error("WebSocket error: #{event.message}") if logger
      end
    end

    private

      def transmit(message)
        if @ws && @connected
          logger.debug("Sending: #{message.to_json}") if logger
          @ws.send(message.to_json)
        else
          @queue << message

          if @queue.length > MAX_QUEUE_LENGTH
            logger.warn("Major Tom Client local queue maxed out at #{MAX_QUEUE_LENGTH} items") if logger
            @queue.pop
          end
        end
      end

      def empty_queue!
        logger.info("Flushing #{@queue.length} queued item(s).") if !@queue.empty? && logger

        while !@queue.empty? && @ws
          transmit(@queue.pop)
          sleep 0.5 # Avoid hitting rate limit
        end
      end
  end
end
