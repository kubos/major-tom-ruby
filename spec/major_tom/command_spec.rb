require 'major_tom/command'

RSpec.describe MajorTom::Command do
  let(:command) {
    MajorTom::Command.new(
      {
      "id" => 6,
      "type" => "testing",
      "system" => "Dev",
      "fields" => [
        {"name" => "limit", "value" => 0},
        {"name" => "subsystem", "value" => "foo"}
      ]
    })
  }

  it "Implements #to_s" do
    expect(command.to_s).to eq "<Command id=6 type='testing' system='Dev' fields=[<Field name='limit' value='0'>, <Field name='subsystem' value='foo'>]>"
  end

  it "allows field access by index" do
    expect(command.fields[0].name).to eq 'limit'
    expect(command.fields[1].value).to eq 'foo'
  end

  it "allows field access by name" do
    expect(command.fields.by_name('limit').name).to eq 'limit'
    expect(command.fields.by_name('subsystem').value).to eq 'foo'
  end
end
