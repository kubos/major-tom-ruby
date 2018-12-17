require 'bundler/setup'
require 'major_tom/threaded_client'
require 'logger'

# The MajorTom::ThreadedClient wraps eventmachine in a Thread and manages it.

# Example usage:
# MT_HOST=wss://your.majortom.host/ MT_GATEWAY_TOKEN=1234567890abcdefg ruby threaded_usage.rb

host = ENV['MT_HOST']
gateway_token = ENV['MT_GATEWAY_TOKEN']
default_system = 'some-satellite'

logger = Logger.new(STDOUT)
logger.level = Logger::DEBUG

major_tom = MajorTom::ThreadedClient.new(
  host: host,
  gateway_token: gateway_token,
  logger: logger,
  default_fields: { system: default_system }
)

major_tom.on_command do |command|
  p command
end

major_tom.connect!

major_tom.telemetry([
                      { subsystem: 'some-subsystem', metric: "random_metric1", value: rand, timestamp: Time.now },
                      { subsystem: nil, metric: "random_metric2", value: rand, timestamp: Time.now },
                    ])

major_tom.join
