require 'json'
require 'faraday'

module MajorTom
  module Script
    class ScriptError < StandardError
    end

    class ScriptDisabledError < ScriptError
    end

    class ScriptRateLimitError < ScriptError
      attr_reader :reset_after, :retry_after, :errors

      def initialize(reset_after, retry_after, errors)
        @reset_after, @retry_after, @errors = reset_after, retry_after, errors
      end

      def to_s
        "<ScriptRateLimitError reset_after='#{reset_after}' retry_after='#{retry_after}' errors='#{errors}'>"
      end
    end

    class ScriptTokenInvalidError < ScriptError
    end

    class InvalidScriptResponse < ScriptError
    end

    class ScriptQueryError < ScriptError
      attr_reader :response, :errors

      def initialize(response, errors)
        @response, @errors = response, errors
      end

      def to_s
        "<ScriptQueryError response='#{response}' errors='#{errors}'>"
      end
    end

    class UnknownObjectError < ScriptError
      attr_reader :object, :name, :parent, :id

      def initialize(object:, name: nil, parent: nil, id: nil)
        @object, @name, @parent, @id = object, name, parent, id
      end

      def to_s
        "<UnknownObjectError object='#{object}' name='#{name}' parent='#{parent}' id='#{id}'>"
      end
    end

    class Client
      attr_reader :uri, :script_token, :ssl, :logger, :basic_auth_username, :basic_auth_password

      # uri: 'https://your.majortom.host'
      # script_token: '1234567890abcdefg'
      # ssl:
      #   verify: true | false,
      #   client_cert: ...,
      #   client_key: ...,
      #   ca_file: ...,
      #   ca_path: ...,
      #   cert_store: ...
      # logger: Logger.new(STDOUT)
      def initialize(uri:, script_token:, ssl: {}, basic_auth_username: nil, basic_auth_password: nil, logger: Logger.new(STDOUT))
        @uri = URI.join(uri, "/")
        @script_token = script_token
        @ssl = ssl
        @basic_auth_username = basic_auth_username
        @basic_auth_password = basic_auth_password
        @logger = logger
        fetch_script_info
      end

      def script_id
        @script_info['id']
      end

      def mission_id
        @script_info['mission']['id']
      end

      def query(query, variables: {}, operation_name: nil, path: nil)
        logger.debug(query)

        conn = Faraday.new(uri, ssl: ssl) do |faraday|
          faraday.use Faraday::Request::Retry
          faraday.use Faraday::Request::BasicAuthentication, basic_auth_username, basic_auth_password if basic_auth_username && basic_auth_password
          faraday.use Faraday::Response::Logger, logger, bodies: true
          faraday.use Faraday::Adapter::NetHttp
        end

        response = conn.post(
          "/script_api/v1/graphql",
          JSON.dump({
            query: query,
            variables: variables,
            operationName: operation_name
          }),
          {
            "Content-Type" => "application/json",
            "X-Script-Token" => script_token
          }
        )

        if response.status == 422
          raise ScriptDisabledError
        elsif response.status == 420
          raise ScriptRateLimitError.new(
                  response.headers['x-ratelimit-resetafter'],
                  response.headers['x-ratelimit-retryafter'],
                  JSON.parse(response.body)["errors"]
          )
        elsif response.status == 403
          raise ScriptTokenInvalidError
        elsif response.status != 200
          raise InvalidScriptResponse
        else
          json_result = JSON.parse(response.body)
          logger.debug(json_result)

          if json_result['errors']
            raise ScriptQueryError.new(response, json_result["errors"])
          end

          if path
            path.split('.').each do |part|
              if json_result
                json_result = json_result[part]
              end
            end
          end

          return json_result
        end
      end

      def system(id: nil, name: nil, return_fields: [])
        default_fields = %w(id name)

        graphql = <<~GRAPHQL
          query SystemQuery($id: ID, $missionId: ID, $name: String) {
            system(id: $id, missionId: $missionId, name: $name) {
              #{(default_fields + return_fields).uniq.join(", ")}
            }
          }
        GRAPHQL

        request = query(graphql,
                        variables: {
                          id: id,
                          missionId: mission_id,
                          name: name
                        },
                        path: 'data.system')

        unless request
          if id
            raise UnknownObjectError.new(object: "system", id: id)
          else
            raise UnknownObjectError.new(object: "system", name: name)
          end
        end

        request
      end

      def metric(id: nil, system_name: nil, subsystem_name: nil, name: nil, return_fields: [])
        default_fields = %w(id name)

        graphql = <<~GRAPHQL
          query MetricQuery($id: ID, $missionId: ID, $systemName: String, $subsystemName: String, $name: String) {
            metric(id: $id, missionId: $missionId, systemName: $systemName, subsystemName: $subsystemName, name: $name) {
              #{(default_fields + return_fields).uniq.join(", ")}
            }
          }
        GRAPHQL

        request = query(graphql,
                        variables: {
                          id: id,
                          missionId: mission_id,
                          systemName: system_name,
                          subsystemName: subsystem_name,
                          name: name
                        },
                        path: 'data.metric')

        unless request
          if id
            raise UnknownObjectError.new(object: "metric", id: id)
          else
            raise UnknownObjectError.new(object: "metric", name: name, parent: subsystem_name)
          end
        end

        request
      end

      private

        def fetch_script_info
          @script_info = query(<<~GRAPHQL, path: 'data.agent.script')
            query {
              agent {
                type
                script {
                  name, id
                  mission { name, id }
                }
              }
            }
          GRAPHQL

          logger.info("Script Info: #{@script_info}")
        end
    end
  end
end
