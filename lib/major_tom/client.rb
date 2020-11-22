require 'faye/websocket'
require 'eventmachine'
require 'json'
require 'base64'
require 'digest'
require 'net/http'
require 'uri'
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

    def on_cancel(&block)
      @cancel_block = block
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
        'id' => command.id
      }

      %w[state payload status output errors
         progress_1_current progress_1_max progress_1_label
         progress_2_current progress_2_max progress_2_label].each do |field|
        if (value = options[field] || options[field.to_sym])
          command_info[field] = value
        end
      end

      transmit(
        'type' => 'command_update',
        'command' => command_info
      )
    end

    def telemetry(entries)
      measurements = entries.map do |entry|
        {
          system: entry['system'] || entry[:system] || default_fields['system'] || default_fields[:system],
          subsystem: entry['subsystem'] || entry[:subsystem] || default_fields['subsystem'] || default_fields[:subsystem],
          metric: entry['metric'] || entry[:metric] || default_fields['metric'] || default_fields[:metric],
          value: entry['value'] || entry[:value],

          # Timestamp is expected to be millisecond unix epoch
          timestamp: ((entry['timestamp'] || entry[:timestamp] || Time.now).to_f * 1000).to_i
        }
      end

      transmit(
        type: 'measurements',
        measurements: measurements
      )
    end

    def events(messages)
      events = messages.map do |entry|
        {
          system: entry['system'] || entry[:system] || default_fields['system'] || default_fields[:system],
          type: entry['type'] || entry[:type] || default_fields['type'] || default_fields[:type],
          message: entry['message'] || entry[:message],
          level: entry['level'] || entry[:level] || default_fields['level'] || default_fields[:level],
          command_id: entry['command_id'] || entry[:command_id],
          debug: entry['debug'] || entry[:debug],

          # Timestamp is expected to be millisecond unix epoch
          timestamp: ((entry['timestamp'] || entry[:timestamp] || Time.now).to_f * 1000).to_i
        }
      end

      transmit(
        type: 'events',
        events: events
      )
    end

    def command_definitions_update(definitions, system = nil)
      transmit(
        type: 'command_definitions_update',
        command_definitions: {
          system: system || default_fields['system'] || default_fields[:system],
          definitions: definitions
        }
      )
    end

    def file_list_update(file_list, system = nil)
      transmit(
          type: 'file_list',
          file_list: {
              system: system || default_fields['system'] || default_fields[:system],
              files: file_list
          }
      )
    end

    def disconnect!
      @ping_timer.cancel if @ping_timer
      @ping_timeout_timer.cancel if @ping_timeout_timer
      @ws.close if @ws
      @connected = false
    end

    def connect!
      logger.info("Connecting to #{uri}") if logger

      headers = { 'X-Gateway-Token' => gateway_token }
      if basic_auth
        headers['Authorization'] = "Basic #{Base64.strict_encode64(basic_auth)}"
      end
      @ws = Faye::WebSocket::Client.new(uri, nil, tls: tls, headers: headers)

      @ws.on :open do |event|
        @connected = true
        logger.info('Connected') if logger

        # Setup ping
        @ping_timer.cancel if @ping_timer
        @ping_timeout_timer.cancel if @ping_timeout_timer
        @ping_timer = EventMachine::PeriodicTimer.new(10) do
          @ping_timeout_timer = EventMachine::Timer.new(2) do
            logger.warn('Ping timeout exceeded. Disconnecting...') if logger
            @ping_timer.cancel if @ping_timer
            @ws.close if @ws
          end

          logger.debug('Pinging') if logger
          @ws.ping 'detecting presence' do
            logger.debug('Ping received.') if logger
            @ping_timeout_timer.cancel if @ping_timeout_timer
          end
        end
      end

      @ws.on :message do |event|
        logger.debug("Got: #{event.data}") if logger

        message = JSON.parse(event.data)
        message_type = message['type']
        if message_type == 'command'
          command = Command.new(message['command'])
          logger.info("Command: #{command}") if logger
          @command_block.call(command) if @command_block
        elsif message_type == 'cancel'
          logger.info("Command cancel from Major Tom: #{message["command"]}") if logger
          @cancel_block.call(message['command']['id']) if @cancel_block
        elsif message_type == 'error'
          logger.warn("Error from Major Tom: #{message["error"]}") if logger
          @error_block.call(message['error']) if @error_block
        elsif message_type == 'rate_limit'
          logger.warn("Rate limit from Major Tom: #{message["rate_limit"]}") if logger
          @rate_limit_block.call(message['rate_limit']) if @rate_limit_block
        elsif message_type == 'transit'
          logger.info("Transit advistory from Major Tom: #{message["transit"]}") if logger
          @transit_block.call(message['transit']) if @transit_block
        elsif message_type == 'hello'
          logger.info("Major Tom says hello: #{message}") if logger
          empty_queue!
          @hello_block.call(message['hello']) if @hello_block
        else
          logger.error("Unknown message type #{message_type} received from Major Tom: #{message}") if logger
        end
      end

      @ws.on :close do |event|
        logger.warn('Connection closed') if logger
        @connected = false
        @ping_timer.cancel if @ping_timer
        @ping_timeout_timer.cancel if @ping_timeout_timer
        @reconnect_timer.cancel if @reconnect_timer
        @ws = nil

        logger.warn("Reconnecting in 30s") if logger
        @reconnect_timer = EventMachine::Timer.new(30) do
          connect! unless @connected
        end
      end

      @ws.on :error do |event|
        logger.error("WebSocket error: #{event.message}") if logger
      end
    end

    def upload_downlinked_file(temp_file_name, on_sat_filename, command_id, system = nil)
      system ||= default_fields['system'] || default_fields[:system]
      image_upload_data = make_direct_upload_request(on_sat_filename, temp_file_name)
      do_image_upload(image_upload_data, temp_file_name)
      confirm_image_upload(image_upload_data, on_sat_filename, system, command_id)
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

      def compute_checksum_in_chunks(io)
        Digest::MD5.new.tap do |checksum|
          while (chunk = io.read(524288))
            checksum << chunk
          end
          io.close
        end.base64digest
      end

      def get_scheme_and_host
        match = /^(.+):\/\/([^\/]+)\//.match(uri)
        scheme = match[1] == 'wss' ? 'https' : 'http'
        return scheme, match[2]
      end

      def make_direct_upload_request(on_sat_filename, local_filename)
        scheme, host = get_scheme_and_host
        uri_object = URI.parse("#{scheme}://#{host}/rails/active_storage/direct_uploads")
        headers = {
            'Content-Type' => 'application/json',
            'X-Gateway-Token' => gateway_token
        }
        if basic_auth
          headers['Authorization'] = "Basic #{Base64.strict_encode64(basic_auth)}"
        end

        body = {
            'filename': on_sat_filename,
            'byte_size': File.size(local_filename),
            'content_type': 'image/jpeg',
            'checksum': compute_checksum_in_chunks(File.open(local_filename))
        }

        http = Net::HTTP.new(uri_object.host, uri_object.port)
        http.use_ssl = true if scheme == "https"
        request = Net::HTTP::Post.new(uri_object.request_uri, headers)
        request.body = body.to_json
        response = http.request(request)
        JSON.parse(response.body)
      end

      def do_image_upload(image_upload_data, temp_file_name)
        url = image_upload_data['direct_upload']['url']
        uri_object = URI.parse(url)
        headers = image_upload_data['direct_upload']['headers']
        http = Net::HTTP.new(uri_object.host, uri_object.port)
        http.use_ssl = true if url.start_with?('https')
        request = Net::HTTP::Put.new(uri_object.request_uri, headers)
        file = File.open(temp_file_name, 'rb')
        request.body = file.read
        http.request(request)
      end

      def confirm_image_upload(image_upload_data, on_sat_filename, system, command_id)
        scheme, host = get_scheme_and_host
        uri_object = URI.parse("#{scheme}://#{host}/gateway_api/v1.0/downlinked_files")
        header = {
            'Content-Type': 'application/json',
            'X-Gateway-Token': gateway_token
        }
        if basic_auth
          header['Authorization'] = "Basic #{Base64.strict_encode64(basic_auth)}"
        end

        body = {
            'signed_id': image_upload_data['signed_id'],
            'name': on_sat_filename,
            'timestamp': Time.now.to_i * 1000,
            'system': system,
            'command_id': command_id
        }
        http = Net::HTTP.new(uri_object.host, uri_object.port)
        http.use_ssl = true if scheme == "https"
        request = Net::HTTP::Post.new(uri_object.request_uri, header)
        request.body = body.to_json
        response = http.request(request)
      end
  end
end
