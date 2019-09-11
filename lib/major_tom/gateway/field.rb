# Field data object.
module MajorTom
  module Gateway
    class Field
      attr_reader :name, :type, :range, :value

      def initialize(params)
        @name = params["name"] || raise("name is required on Fields")
        @value = params["value"] || raise("value is required on Fields")
      end

      def to_s
        "<Field name='#{name}' value='#{value}'>"
      end
    end
  end
end
