require 'bundler/setup'
require 'major_tom/script/client'
require 'logger'

# Example usage:
# MT_URI=https://your.majortom.host MT_SCRIPT_TOKEN=1234567890abcdefg ruby basic_usage.rb

uri = ENV['MT_URI']
script_token = ENV['MT_SCRIPT_TOKEN']

logger = Logger.new(STDOUT)
logger.level = Logger::DEBUG

client = MajorTom::Script::Client.new(
  uri: uri,
  script_token: script_token,
  logger: logger
)

system = client.system(id: 1, return_fields: ['metrics { nodes { name, latest { timestamp, value } } }'])
p system
