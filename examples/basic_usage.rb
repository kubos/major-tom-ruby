require 'bundler/setup'
require 'major_tom/client'
require 'logger'

# The MajorTom::Client uses eventmachine and expects you to start the reactor wherever is appropriate for your application.

# Example usage:
# MT_HOST=wss://your.majortom.host/ MT_GATEWAY_TOKEN=1234567890abcdefg ruby basic_usage.rb

host = ENV['MT_HOST']
gateway_token = ENV['MT_GATEWAY_TOKEN']
default_system = 'some-satellite'

EM.run do
  logger = Logger.new(STDOUT)
  logger.level = Logger::DEBUG

  client = MajorTom::Client.new(
    host: host,
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

  client.connect!

  client.telemetry([
    { subsystem: 'some-subsystem', metric: "random_metric1", value: rand, timestamp: Time.now },
    { subsystem: nil, metric: "random_metric2", value: rand, timestamp: Time.now },
  ])
end
