# frozen_string_literal: true

module ResultHelpers
  private

  def assert_result(result, value, is_success, debug: false)
    debugger if debug
    expect(result.value).to eq value
    expect(result.valid?).to be(is_success)
  end
end
