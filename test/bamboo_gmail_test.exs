defmodule Bamboo.GmailAdapterTest do
  use ExUnit.Case

  alias Bamboo.Email
  alias Bamboo.GmailAdapter
  alias Bamboo.GmailAdapter.Errors.{ConfigError}

  doctest Bamboo.GmailAdapter

  @invalid_config %{
    app: :mailer,
    adapter: :adapter
  }

  test "invalid configuration raises ConfigError" do
    assert {:error, %ConfigError{}} = GmailAdapter.handle_config(@invalid_config)
  end

  test "missing env-backed sub returns an ArgumentError tuple" do
    env_var = "BAMBOO_GMAIL_TEST_MISSING_SUB"
    original_value = System.get_env(env_var)

    System.delete_env(env_var)

    on_exit(fn ->
      case original_value do
        nil -> System.delete_env(env_var)
        value -> System.put_env(env_var, value)
      end
    end)

    assert {:error, %ArgumentError{} = error} =
             GmailAdapter.deliver(email(), %{sub: {:system, env_var}, sandbox: true})

    assert error.message == "Environment variable '#{env_var}' not found"
  end

  defp email do
    Email.new_email(
      to: [{"Recipient", "to@example.com"}],
      cc: [],
      bcc: [],
      from: {"Sender", "from@example.com"},
      subject: "subject",
      text_body: "body"
    )
  end
end
