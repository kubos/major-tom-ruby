require_relative 'fields'

# Command data object.
module MajorTom
  module Gateway
    class Command
      attr_reader :id, :type, :system, :fields

      def initialize(params)
        @id = params["id"] || raise("id is required on Commands")
        @type = params["type"] || raise("type is required on Commands")
        @system = params["system"] || raise("system is required on Commands")
        @fields = Fields.new(params["fields"])
      end

      def to_s
        "<Command id=#{id} type='#{type}' system='#{system}' fields=#{fields}>"
      end
    end
  end
end
