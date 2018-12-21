require_relative 'field'

module MajorTom
  class Fields
    attr_reader :fields

    def initialize(json_fields)
      @fields = (json_fields || []).map { |field| Field.new(field) }
    end

    def by_name(name)
      @fields.detect { |field| field.name == name }
    end

    def [](index)
      @fields[index]
    end

    def each(&block)
      @fields.each(&block)
    end

    def to_s
      "[#{fields.map(&:to_s).join(', ')}]"
    end
  end
end
