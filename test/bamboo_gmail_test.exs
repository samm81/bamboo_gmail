defmodule Bamboo.GmailAdapterTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

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

  test "sandbox rendering preserves display names from normalized bamboo addresses" do
    env_var = "BAMBOO_GMAIL_TEST_MISSING_SUB"
    original_value = System.get_env(env_var)

    System.delete_env(env_var)

    on_exit(fn ->
      case original_value do
        nil -> System.delete_env(env_var)
        value -> System.put_env(env_var, value)
      end
    end)

    output =
      capture_io(fn ->
        assert {:error, %ArgumentError{}} =
                 GmailAdapter.deliver(named_email(), %{sub: {:system, env_var}, sandbox: true})
      end)

    assert output =~ "From: =?UTF-8?Q?"
    assert output =~ "Jos=C3=A9"
    assert output =~ "<from@example.com>"
    assert output =~ "To: =?UTF-8?Q?"
    assert output =~ "Ana=C3=AFs"
    assert output =~ "<to@example.com>"
    assert output =~ "Cc: =?UTF-8?Q?"
    assert output =~ "Bcc: =?UTF-8?Q?"
  end

  test "sandbox rendering adds utf-8 charset for non-ascii text bodies" do
    env_var = "BAMBOO_GMAIL_TEST_MISSING_SUB"
    original_value = System.get_env(env_var)

    System.delete_env(env_var)

    on_exit(fn ->
      case original_value do
        nil -> System.delete_env(env_var)
        value -> System.put_env(env_var, value)
      end
    end)

    output =
      capture_io(fn ->
        assert {:error, %ArgumentError{}} =
                 GmailAdapter.deliver(unicode_body_email(), %{
                   sub: {:system, env_var},
                   sandbox: true
                 })
      end)

    assert output =~ "Content-Type: text/plain; charset=UTF-8"
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

  defp named_email do
    Email.new_email(
      to: [{"Anaïs Recipient", "to@example.com"}],
      cc: [{"Renée Carbon", "cc@example.com"}],
      bcc: [{"Björk Hidden", "bcc@example.com"}],
      from: {"José Sender", "from@example.com"},
      subject: "subject",
      text_body: "body"
    )
  end

  defp unicode_body_email do
    Email.new_email(
      to: [{"Recipient", "to@example.com"}],
      cc: [],
      bcc: [],
      from: {"Sender", "from@example.com"},
      subject: "subject",
      text_body: "café body"
    )
  end
end
