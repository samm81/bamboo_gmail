defmodule Bamboo.GmailAdapterTest.SandboxMailer do
  use Bamboo.Mailer, otp_app: :bamboo_gmail
end

defmodule Bamboo.GmailAdapterTest.InvalidConfigMailer do
  use Bamboo.Mailer, otp_app: :bamboo_gmail
end

defmodule Bamboo.GmailAdapterTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Bamboo.Email
  alias Bamboo.GmailAdapter
  alias Bamboo.GmailAdapter.Errors.{ConfigError, HTTPError}
  alias Bamboo.GmailAdapterTest.{InvalidConfigMailer, SandboxMailer}

  doctest Bamboo.GmailAdapter

  test "missing sub raises ConfigError through the Bamboo mailer config path" do
    original_config = Application.get_env(:bamboo_gmail, InvalidConfigMailer)

    Application.put_env(:bamboo_gmail, InvalidConfigMailer, adapter: GmailAdapter)

    on_exit(fn ->
      case original_config do
        nil -> Application.delete_env(:bamboo_gmail, InvalidConfigMailer)
        value -> Application.put_env(:bamboo_gmail, InvalidConfigMailer, value)
      end
    end)

    assert_raise ConfigError, ~r/Must provide `sub` field in config/, fn ->
      InvalidConfigMailer.deliver_now(default_email())
    end
  end

  test "missing sub returns ConfigError through direct adapter delivery" do
    assert {:error, %ConfigError{} = error} = GmailAdapter.deliver(default_email(), %{})

    assert error.message =~ "Must provide `sub` field in config"
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
             GmailAdapter.deliver(email(), %{sub: {:system, env_var}})

    assert error.message == "Environment variable '#{env_var}' not found"
  end

  test "gmail api rejections return HTTPError tuples" do
    response = %HTTPoison.Response{status_code: 401, body: ~s({"error":"invalid_grant"})}

    assert {:error, %HTTPError{} = error} =
             GmailAdapter.deliver(email(), %{
               sub: "sub@example.com",
               token_fetcher: fn "sub@example.com" -> {:ok, "test-token"} end,
               request_sender: fn url, body, headers ->
                 assert url == "https://www.googleapis.com/gmail/v1/users/me/messages/send"
                 assert body =~ ~s("raw": ")

                 assert headers == [
                          Authorization: "Bearer test-token",
                          "Content-Type": "application/json"
                        ]

                 {:ok, response}
               end
             })

    assert error.message =~ "Error making HTTP request"
    assert error.message =~ "status_code: 401"
    assert error.message =~ "invalid_grant"
  end

  test "sandbox delivery stays local and skips access token lookup" do
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
        assert {:ok, encoded_message} =
                 GmailAdapter.deliver(email(), %{sub: {:system, env_var}, sandbox: true})

        assert is_binary(encoded_message)
      end)

    refute output =~ "[sandbox] <access token>"
    assert output =~ "[sandbox] <base64url encoded message>"
  end

  test "sandbox mailer config path does not require sub" do
    original_config = Application.get_env(:bamboo_gmail, SandboxMailer)

    Application.put_env(:bamboo_gmail, SandboxMailer,
      adapter: GmailAdapter,
      sandbox: true
    )

    on_exit(fn ->
      case original_config do
        nil -> Application.delete_env(:bamboo_gmail, SandboxMailer)
        value -> Application.put_env(:bamboo_gmail, SandboxMailer, value)
      end
    end)

    output =
      capture_io(fn ->
        assert {:ok, delivered_email} = SandboxMailer.deliver_now(default_email())
        assert delivered_email.subject == "subject"
      end)

    assert output =~ "[sandbox] <base64url encoded message>"
  end

  test "sandbox rendering preserves display names from normalized bamboo addresses" do
    output =
      capture_io(fn ->
        assert {:ok, encoded_message} = GmailAdapter.deliver(named_email(), %{sandbox: true})

        assert is_binary(encoded_message)
      end)

    assert output =~ "From: =?UTF-8?Q?"
    assert output =~ "Jos=C3=A9"
    assert output =~ "<from@example.com>"
    assert output =~ "To: =?UTF-8?Q?"
    assert output =~ "Ana=C3=AFs"
    assert output =~ "<to@example.com>"
    assert output =~ "Cc: =?UTF-8?Q?"
    refute output =~ "Bcc:"
  end

  test "sandbox rendering forwards custom bamboo headers into the mime message" do
    capture_io(fn ->
      test_pid = self()

      assert {:ok, encoded_message} = GmailAdapter.deliver(header_email(), %{sandbox: true})

      send(test_pid, {:encoded_message, encoded_message})
    end)

    assert_receive {:encoded_message, encoded_message}

    rendered_message = Base.url_decode64!(encoded_message)

    assert rendered_message =~ ~s(Reply-To: "Reply Sender" <reply@example.com>)
    assert rendered_message =~ "X-Trace-Id: trace-123"
  end

  test "sandbox rendering adds utf-8 charset for non-ascii text bodies" do
    output =
      capture_io(fn ->
        assert {:ok, encoded_message} =
                 GmailAdapter.deliver(unicode_body_email(), %{sandbox: true})

        assert is_binary(encoded_message)
      end)

    assert output =~ "Content-Type: text/plain; charset=UTF-8"
  end

  test "sandbox delivery skips omitted cc and bcc lists" do
    output =
      capture_io(fn ->
        assert {:ok, encoded_message} = GmailAdapter.deliver(default_email(), %{sandbox: true})

        assert is_binary(encoded_message)
      end)

    refute output =~ "Cc:"
    refute output =~ "Bcc:"
    assert output =~ "to@example.com"
  end

  test "sandbox rendering encodes non-ascii attachment filenames with rfc2231" do
    output =
      capture_io(fn ->
        assert {:ok, encoded_message} = GmailAdapter.deliver(attachment_email(), %{sandbox: true})

        assert is_binary(encoded_message)
      end)

    assert output =~
             ~s|Content-Disposition: attachment; filename*=UTF-8''r%C3%A9sum%C3%A9%20final.pdf|

    refute output =~ "filename=résumé final.pdf"
  end

  test "sandbox rendering preserves attachment content type and normalizes bare content ids" do
    output =
      capture_io(fn ->
        assert {:ok, encoded_message} =
                 GmailAdapter.deliver(inline_attachment_email(), %{sandbox: true})

        assert is_binary(encoded_message)
      end)

    assert output =~ "Content-Type: image/webp"
    assert output =~ "Content-Id: <logo-123>"
    assert output =~ "Content-Type: multipart/related;"
    assert output =~ "Content-Disposition: inline; filename=logo.png"
    refute output =~ "Content-Type: application/octet-stream"
    refute output =~ "Content-Disposition: attachment; filename=logo.png"
  end

  test "sandbox rendering preserves already bracketed attachment content ids" do
    output =
      capture_io(fn ->
        assert {:ok, encoded_message} =
                 GmailAdapter.deliver(inline_attachment_email("<logo-123>"), %{sandbox: true})

        assert is_binary(encoded_message)
      end)

    assert output =~ "Content-Id: <logo-123>"
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

  defp default_email do
    Email.new_email(
      to: [{"Recipient", "to@example.com"}],
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

  defp header_email do
    default_email()
    |> Email.put_header("Reply-To", {"Reply Sender", "reply@example.com"})
    |> Email.put_header("X-Trace-Id", "trace-123")
  end

  defp attachment_email do
    Email.new_email(
      to: [{"Recipient", "to@example.com"}],
      cc: [],
      bcc: [],
      from: {"Sender", "from@example.com"},
      subject: "subject",
      text_body: "body"
    )
    |> Email.put_attachment(%Bamboo.Attachment{filename: "résumé final.pdf", data: "data"})
  end

  defp inline_attachment_email(content_id \\ "logo-123") do
    Email.new_email(
      to: [{"Recipient", "to@example.com"}],
      cc: [],
      bcc: [],
      from: {"Sender", "from@example.com"},
      subject: "subject",
      html_body: ~s(<img src="cid:logo-123" alt="logo" />)
    )
    |> Email.put_attachment(%Bamboo.Attachment{
      filename: "logo.png",
      data: "data",
      content_type: "image/webp",
      content_id: content_id
    })
  end
end
