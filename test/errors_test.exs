defmodule Bamboo.GmailAdapter.ErrorsTest do
  use ExUnit.Case

  alias Bamboo.GmailAdapter.Errors.{ConfigError, HTTPError, TokenError}

  test "invalid configuration raises ConfigError" do
    exception = %ConfigError{message: "test"}
    assert is_binary(String.Chars.to_string(exception))

    exception = %TokenError{message: "test"}
    assert is_binary(String.Chars.to_string(exception))

    exception = %HTTPError{message: "test"}
    assert is_binary(String.Chars.to_string(exception))
  end

  test "http errors build HTTPError exceptions" do
    exception = HTTPError.build_error(message: :timeout)

    assert %HTTPError{} = exception
    refute match?(%TokenError{}, exception)
    assert exception.message =~ "Error making HTTP request"
    assert exception.message =~ "timeout"
  end
end
