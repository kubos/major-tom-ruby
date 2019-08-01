require 'bundler/setup'
require 'major_tom/client'
require 'logger'

# The MajorTom::Client uses eventmachine and expects you to start the reactor wherever is appropriate for your application.

# Example usage:
# MT_URI=wss://your.majortom.host/gateway_api/v1.0 MT_GATEWAY_TOKEN=1234567890abcdefg ruby basic_usage.rb

uri = ENV['MT_URI']
gateway_token = ENV['MT_GATEWAY_TOKEN']
default_system = ENV['MT_SYSTEM'] || 'some-satellite'

EM.run do
  logger = Logger.new(STDOUT)
  logger.level = Logger::DEBUG

  client = MajorTom::Client.new(
    uri: uri,
    gateway_token: gateway_token,
    logger: logger,
    default_fields: { system: default_system }
  )

  client.on_hello do |hello_message|
    p hello_message
  end

  client.on_command do |command|
    p command
  end

  client.on_error do |error|
    p error
  end

  client.on_rate_limit do |rate_limit|
    p rate_limit
  end

  client.connect!

  client.telemetry([
    { subsystem: 'some-subsystem', metric: "random_metric1", value: rand, timestamp: Time.now },
    { subsystem: nil, metric: "random_metric2", value: rand, timestamp: Time.now },
  ])
end
