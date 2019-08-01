require 'bundler/setup'
require 'major_tom/threaded_client'
require 'logger'

# The MajorTom::ThreadedClient wraps eventmachine in a Thread and manages it.

# Example usage:
# MT_URI=wss://your.majortom.host/gateway_api/v1.0 MT_GATEWAY_TOKEN=1234567890abcdefg ruby threaded_usage.rb

uri = ENV['MT_URI']
gateway_token = ENV['MT_GATEWAY_TOKEN']
default_system = ENV['MT_SYSTEM'] || 'some-satellite'

logger = Logger.new(STDOUT)
logger.level = Logger::DEBUG

major_tom = MajorTom::ThreadedClient.new(
  uri: uri,
  gateway_token: gateway_token,
  logger: logger,
  default_fields: { system: default_system, level: "nominal" }
)

major_tom.on_error do |error|
  p error
end

major_tom.on_rate_limit do |rate_limit|
  p rate_limit
end

major_tom.on_command do |command|
  p command
  major_tom.command_update(command, state: "preparing_on_gateway", status: "Command received by gateway. I'll do something now...")
end

major_tom.connect!

major_tom.telemetry([
                      { subsystem: 'some-subsystem', metric: "random_metric1", value: rand, timestamp: Time.now },
                      { subsystem: 'another-subsystem', metric: "random_metric2", value: rand, timestamp: Time.now },
                    ])

major_tom.events([
                   { type: "ClientInformation", message: "Client has started", debug: { system_time: `date` }, timestamp: Time.now }
                 ])

major_tom.join
