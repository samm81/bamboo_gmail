defmodule Bamboo.GmailAdapter do
  @moduledoc """
  Sends email using the Gmail API with OAuth2 authentication

  There are a few preconditions that must be met before this adapter can be used to send email:
  1. Admin access to a GSuite account
  2. Implement [server-side authorization](https://developers.google.com/gmail/api/auth/web-server)
  3. Grant the service account domain-wide authority
  4. Authorize API client with required scopes

  Some application settings must be configured. See the [example section](#module-example-config) below.

  ---

  ## Configuration

  | Setting | Description | Required? |
  | ---------- | ---------- | ---------- |
  | `adapter` | Bamboo adapter in use (`Bamboo.GmailAdapter`). | Yes |
  | `sub` | Email address the service account is impersonating (address the email is sent from).  If impersonation is not needed, then `nil` (it is likely needed). | Yes |
  |`sandbox` | Development mode that does not send email.  Details of the API call are instead output to the elixir console. | No |
  | `json` | Google auth crendentials must be provided in JSON format to the `:goth` app.  These are generated in the [Google Developers Console](https://console.developers.google.com/). | Yes |


  #### Note:

  *Secrets such as the service account sub, and the auth credentials should not
  be commited to version control.*

  Instead, pass in via environment variables using a tuple:
      {:system, "SUB_ADDRESS"}

  Or read in from a file:
      "creds.json" |> File.read!

  ---

  ## Example Config

      config :app_name, GmailAdapterTestWeb.Mailer,
        adapter: Bamboo.GmailAdapter,
        sub: {:system, "SUB_ADDRESS"},
        sandbox: false

      # Google auth credentials must be provided to the `goth` app
      config :goth, json: {:system, "GCP_CREDENTIALS"}
  """

  import Bamboo.GmailAdapter.RFC2822, only: [render: 1]
  alias Bamboo.GmailAdapter.Errors.{ConfigError, TokenError, HTTPError}

  @gmail_auth_scope "https://www.googleapis.com/auth/gmail.send"
  @gmail_send_url "https://www.googleapis.com/gmail/v1/users/me/messages/send"
  @behaviour Bamboo.Adapter

  def deliver(email, config) do
    handle_dispatch(email, config)
  end

  def handle_config(config) do
    case validate_config_fields(config) do
      {:error, %ConfigError{} = error} -> raise error
      valid_config -> valid_config
    end
  end

  def supports_attachments?, do: true

  defp handle_dispatch(email, config = %{sandbox: true}) do
    log_to_sandbox(config, label: "config")
    log_to_sandbox(email, label: "email")

    encoded_message =
      build_message(email)
      |> render()
      |> log_to_sandbox(label: "MIME message")
      |> Base.url_encode64()
      |> log_to_sandbox(label: "base64url encoded message")

    {:ok, encoded_message}
  end

  defp handle_dispatch(email, config) do
    message = build_message(email)

    with {:ok, token} <- fetch_access_token(config) do
      build_request(token, message, config)
    end
  end

  defp build_message(email) do
    Mail.build_multipart()
    |> put_to(email)
    |> put_cc(email)
    |> put_bcc(email)
    |> put_from(email)
    |> put_subject(email)
    |> put_headers(email)
    |> put_text_body(email)
    |> put_html_body(email)
    |> put_attachments(email)
  end

  defp put_to(message, %{to: recipients}) do
    Mail.put_to(message, recipients)
  end

  defp put_cc(message, %{cc: nil}), do: message

  defp put_cc(message, %{cc: recipients}) do
    Mail.put_cc(message, recipients)
  end

  defp put_bcc(message, %{bcc: nil}), do: message

  defp put_bcc(message, %{bcc: recipients}) do
    Mail.put_bcc(message, recipients)
  end

  defp put_from(message, %{from: sender}) do
    Mail.put_from(message, sender)
  end

  defp put_subject(message, %{subject: subject}) do
    Mail.put_subject(message, subject)
  end

  defp put_headers(message, %{headers: headers}) when is_map(headers) do
    Enum.reduce(headers, message, fn {key, value}, acc ->
      Mail.Message.put_header(acc, key, value)
    end)
  end

  defp put_headers(message, _email), do: message

  defp put_html_body(message, %{html_body: nil}), do: message

  defp put_html_body(message, %{html_body: html_body}) do
    Mail.put_html(message, html_body)
  end

  defp put_text_body(message, %{text_body: nil}), do: message

  defp put_text_body(message, %{text_body: text_body}) do
    Mail.put_text(message, text_body)
  end

  defp put_attachments(message, %{attachments: attachments}) do
    put_attachments_helper(message, attachments)
  end

  defp put_attachments_helper(message, [head | tail]) do
    put_attachments_helper(message, head)
    |> put_attachments_helper(tail)
  end

  defp put_attachments_helper(message, %Bamboo.Attachment{} = attachment) do
    %{filename: filename, data: data, content_type: content_type, content_id: content_id} =
      attachment

    attachment =
      Mail.Message.build_attachment({filename, data})
      |> maybe_put_attachment_content_type(content_type)
      |> maybe_put_attachment_content_id(content_id)
      |> Mail.Message.put_header(:content_length, byte_size(data))

    Mail.Message.put_part(message, attachment)
  end

  defp put_attachments_helper(message, _no_attachments) do
    message
  end

  defp maybe_put_attachment_content_type(message, nil), do: message

  defp maybe_put_attachment_content_type(message, content_type) do
    Mail.Message.put_header(message, :content_type, content_type)
  end

  defp maybe_put_attachment_content_id(message, nil), do: message

  defp maybe_put_attachment_content_id(message, content_id) do
    Mail.Message.put_header(message, :content_id, content_id)
  end

  defp build_request(token, message, config) do
    header = build_request_header(token)

    render(message)
    |> Base.url_encode64()
    |> build_request_body()
    |> send_request(header, @gmail_send_url, config)
  end

  defp send_request(body, header, url, config) do
    request_sender(config).(url, body, header)
    |> handle_response()
  end

  defp handle_response({:ok, %HTTPoison.Response{status_code: status_code} = response})
       when status_code >= 200 and status_code < 300 do
    {:ok, response}
  end

  defp handle_response({:ok, %HTTPoison.Response{} = response}) do
    handle_error(:http, response)
  end

  defp handle_response({:error, error}) do
    handle_error(:http, error)
  end

  defp validate_config_fields(config = %{sandbox: true}), do: config

  # Right now `sub` is the only required field.
  # TODO: Generalize this function
  defp validate_config_fields(config = %{sub: _}), do: config

  defp validate_config_fields(_no_match) do
    handle_error(:conf, "sub")
  end

  defp fetch_access_token(config) do
    with {:ok, sub} <- get_sub(config),
         {:ok, token} <- get_access_token(sub, config) do
      {:ok, token}
    end
  end

  defp get_sub(%{sub: {:system, env_var}}), do: validate_env_var(env_var)
  defp get_sub(%{sub: sub}), do: {:ok, sub}

  defp validate_env_var(env_var) do
    case System.get_env(env_var) do
      nil -> handle_error(:env, "Environment variable '#{env_var}' not found")
      var -> {:ok, var}
    end
  end

  defp get_access_token(sub, config) do
    case token_fetcher(config).(sub) do
      {:ok, token} -> {:ok, token}
      {:error, error} -> handle_error(:auth, error)
    end
  end

  defp token_fetcher(config) do
    Map.get(config, :token_fetcher, &fetch_goth_access_token/1)
  end

  defp fetch_goth_access_token(sub) do
    case Goth.Token.for_scope(@gmail_auth_scope, sub) do
      {:ok, token} -> {:ok, Map.get(token, :token)}
      {:error, error} -> {:error, error}
    end
  end

  defp handle_error(scope, error) do
    case scope do
      :auth -> {:error, TokenError.build_error(message: error)}
      :http -> {:error, HTTPError.build_error(message: error)}
      :conf -> {:error, ConfigError.build_error(field: error)}
      :env -> {:error, ArgumentError.exception(error)}
    end
  end

  defp build_request_header(token) do
    [Authorization: "Bearer #{token}", "Content-Type": "application/json"]
  end

  defp build_request_body(message) do
    "{\"raw\": \"#{message}\"}"
  end

  defp request_sender(config) do
    Map.get(config, :request_sender, &HTTPoison.post/3)
  end

  defp log_to_sandbox(entity, label: label) do
    IO.puts("[sandbox] <#{label}> #{inspect(entity)}\n")
    entity
  end
end
