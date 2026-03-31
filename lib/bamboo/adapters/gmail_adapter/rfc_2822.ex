defmodule Bamboo.GmailAdapter.RFC2822 do
  import Mail.Message, only: [match_content_type?: 2]

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @encoded_word_max_length 64
  @reserved_header_chars [?=, ??, ?_]

  @moduledoc """
  RFC2822 Parser:  Adapted from [elixir-mail](https://github.com/DockYard/elixir-mail)

  Will attempt to render a valid RFC2822 message
  from a `%Mail.Message{}` data model.

      Mail.Renderers.RFC2822.render(message)

  The email validation regex defaults to `~r/\w+@\w+\.\w+/`
  and can be overridden with the following config:

      config :mail, email_regex: custom_regex
  """

  @blacklisted_headers ["bcc"]
  @address_types ["From", "To", "Reply-To", "Cc", "Bcc"]

  # https://tools.ietf.org/html/rfc2822#section-3.4.1
  @email_validation_regex Application.compile_env(
                            :mail,
                            :email_regex,
                            ~r/[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}/
                          )

  @doc """
  Renders a message according to the RFC2882 spec
  """
  def render(%Mail.Message{multipart: true} = message) do
    message
    |> reorganize
    |> Mail.Message.put_header(:mime_version, "1.0")
    |> render_part()
  end

  def render(%Mail.Message{} = message),
    do: render_part(message)

  @doc """
  Render an individual part

  An optional function can be passed used during the rendering of each
  individual part
  """
  def render_part(message, render_part_function \\ &render_part/1)

  def render_part(%Mail.Message{multipart: true} = message, fun) do
    boundary = Mail.Message.get_boundary(message)
    message = Mail.Message.put_boundary(message, boundary)

    headers = render_headers(message.headers, @blacklisted_headers)
    boundary = "--#{boundary}"

    parts =
      render_parts(message.parts, fun)
      |> Enum.join("\r\n\r\n#{boundary}\r\n")

    "#{headers}\r\n\r\n#{boundary}\r\n#{parts}\r\n#{boundary}--"
  end

  def render_part(%Mail.Message{} = message, _fun) do
    message = maybe_put_utf8_charset(message)
    encoded_body = encode(message.body, message)
    "#{render_headers(message.headers, @blacklisted_headers)}\r\n\r\n#{encoded_body}"
  end

  def render_parts(parts, fun \\ &render_part/1) when is_list(parts),
    do: Enum.map(parts, &fun.(&1))

  @doc """
  Will render a given header according to the RFC2882 spec
  """
  def render_header(key, value)

  def render_header(key, value) when is_atom(key),
    do: render_header(Atom.to_string(key), value)

  def render_header(key, value) do
    key =
      key
      |> String.replace("_", "-")
      |> String.split("-")
      |> Enum.map(&String.capitalize(&1))
      |> Enum.join("-")

    key <> ": " <> render_header_value(key, value)
  end

  defp render_header_value("Date", date_time),
    do: timestamp_from_erl(date_time)

  defp render_header_value(address_type, addresses)
       when is_list(addresses) and address_type in @address_types,
       do:
         Enum.map(addresses, &render_address(&1))
         |> Enum.join(", ")

  defp render_header_value(address_type, address) when address_type in @address_types,
    do: render_address(address)

  defp render_header_value("Content-Transfer-Encoding" = key, value) when is_atom(value) do
    value =
      value
      |> Atom.to_string()
      |> String.replace("_", "-")

    render_header_value(key, value)
  end

  defp render_header_value(_key, [value | subtypes]),
    do:
      Enum.join(
        [encode_header_value(value, :quoted_printable) | render_subtypes(subtypes)],
        "; "
      )

  defp render_header_value(key, value),
    do: render_header_value(key, List.wrap(value))

  defp validate_address(address) do
    case valid_address?(address) do
      true ->
        address

      false ->
        raise ArgumentError,
          message: """
          The email address `#{address}` is invalid.
          """
    end
  end

  defp valid_address?(address) do
    not contains_control_char?(address) and matches_entire_address?(address)
  end

  defp contains_control_char?(<<>>), do: false
  defp contains_control_char?(<<byte, _rest::binary>>) when byte < 32 or byte == 127, do: true
  defp contains_control_char?(<<_byte, rest::binary>>), do: contains_control_char?(rest)

  defp matches_entire_address?(address) do
    case Regex.run(@email_validation_regex, address) do
      [match | _captures] when match == address -> true
      _ -> false
    end
  end

  defp render_address({name, email}) do
    "#{encode_header_value(~s("#{name}"), :quoted_printable)} <#{validate_address(email)}>"
  end

  defp render_address(email), do: validate_address(email)
  defp render_subtypes([]), do: []

  defp render_subtypes([{key, value} | subtypes]) when is_atom(key),
    do: render_subtypes([{Atom.to_string(key), value} | subtypes])

  defp render_subtypes([{"boundary", value} | subtypes]) do
    [~s(boundary=#{quote_parameter_value(value)}) | render_subtypes(subtypes)]
  end

  defp render_subtypes([{key, value} | subtypes]) do
    key = String.replace(key, "_", "-")

    [render_subtype(key, value) | render_subtypes(subtypes)]
  end

  defp render_subtype(key, value) do
    case encode_parameter_value(value) do
      {:regular, encoded_value} -> "#{key}=#{encoded_value}"
      {:extended, encoded_value} -> "#{key}*=#{encoded_value}"
    end
  end

  defp encode_parameter_value(value) do
    value = to_string(value)

    cond do
      parameter_token_safe?(value) ->
        {:regular, value}

      requires_extended_parameter_encoding?(value) ->
        {:extended, "UTF-8''" <> encode_extended_parameter_value(value)}

      true ->
        {:regular, quote_parameter_value(value)}
    end
  end

  defp parameter_token_safe?(<<>>), do: false

  defp parameter_token_safe?(<<byte>>) when byte <= 32 or byte >= 127,
    do: false

  defp parameter_token_safe?(<<byte>>)
       when byte in [?(, ?), ?<, ?>, ?@, ?,, ?;, ?:, ?\\, ?", ?/, ?[, ?], ??, ?=],
       do: false

  defp parameter_token_safe?(<<_byte>>), do: true

  defp parameter_token_safe?(<<byte, _rest::binary>>) when byte <= 32 or byte >= 127,
    do: false

  defp parameter_token_safe?(<<byte, _rest::binary>>)
       when byte in [?(, ?), ?<, ?>, ?@, ?,, ?;, ?:, ?\\, ?", ?/, ?[, ?], ??, ?=],
       do: false

  defp parameter_token_safe?(<<_byte, rest::binary>>), do: parameter_token_safe?(rest)

  defp requires_extended_parameter_encoding?(<<>>), do: false
  defp requires_extended_parameter_encoding?(<<byte, _rest::binary>>) when byte < 32, do: true
  defp requires_extended_parameter_encoding?(<<127, _rest::binary>>), do: true
  defp requires_extended_parameter_encoding?(<<byte, _rest::binary>>) when byte > 127, do: true

  defp requires_extended_parameter_encoding?(<<_byte, rest::binary>>),
    do: requires_extended_parameter_encoding?(rest)

  defp quote_parameter_value(value) do
    escaped_value =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped_value}")
  end

  defp encode_extended_parameter_value(value) do
    URI.encode(value, &extended_parameter_char?/1)
  end

  defp extended_parameter_char?(char)
       when char in ?0..?9 or char in ?A..?Z or char in ?a..?z,
       do: true

  defp extended_parameter_char?(char)
       when char in [?!, ?#, ?$, ?&, ?+, ?-, ?., ?^, ?_, ?`, ?|, ?~],
       do: true

  defp extended_parameter_char?(_char), do: false

  defp encode_header_value(header_value, :quoted_printable) when is_binary(header_value) do
    if requires_encoding?(header_value) do
      header_value
      |> encode_quoted_printable_header(@encoded_word_max_length)
      |> wrap_encoded_words()
    else
      header_value
    end
  end

  defp encode_header_value(header_value, _encoding) do
    to_string(header_value)
  end

  defp requires_encoding?(<<>>), do: false
  defp requires_encoding?(<<byte, _rest::binary>>) when byte > 126, do: true
  defp requires_encoding?(<<byte, _rest::binary>>) when byte < 32 and byte != ?\t, do: true
  defp requires_encoding?(<<_byte, rest::binary>>), do: requires_encoding?(rest)

  defp wrap_encoded_words(value) do
    :binary.split(value, "=\r\n", [:global])
    |> Enum.map(fn chunk -> <<"=?UTF-8?Q?", chunk::binary, "?=">> end)
    |> Enum.join()
  end

  defp encode_quoted_printable_header(string, max_length, acc \\ <<>>, line_length \\ 0)

  defp encode_quoted_printable_header(<<>>, _max_length, acc, _line_length), do: acc

  defp encode_quoted_printable_header(
         <<char, tail::binary>>,
         max_length,
         acc,
         line_length
       )
       when char in ?!..?~ and char not in @reserved_header_chars do
    if line_length < max_length - 1 do
      encode_quoted_printable_header(tail, max_length, acc <> <<char>>, line_length + 1)
    else
      encode_quoted_printable_header(tail, max_length, acc <> "=\r\n" <> <<char>>, 1)
    end
  end

  defp encode_quoted_printable_header(
         <<char, tail::binary>>,
         max_length,
         acc,
         line_length
       )
       when char in [?\t, ?\s] do
    if byte_size(tail) > 0 do
      if line_length < max_length - 1 do
        encode_quoted_printable_header(tail, max_length, acc <> <<char>>, line_length + 1)
      else
        encode_quoted_printable_header(tail, max_length, acc <> "=\r\n" <> <<char>>, 1)
      end
    else
      escaped = "=" <> Base.encode16(<<char>>)
      line_length = line_length + byte_size(escaped)

      if line_length <= max_length do
        encode_quoted_printable_header(tail, max_length, acc <> escaped, line_length)
      else
        encode_quoted_printable_header(
          tail,
          max_length,
          acc <> "=\r\n" <> escaped,
          byte_size(escaped)
        )
      end
    end
  end

  defp encode_quoted_printable_header(<<char, tail::binary>>, max_length, acc, line_length) do
    escaped = "=" <> Base.encode16(<<char>>)
    line_length = line_length + byte_size(escaped)

    if line_length < max_length do
      encode_quoted_printable_header(tail, max_length, acc <> escaped, line_length)
    else
      encode_quoted_printable_header(
        tail,
        max_length,
        acc <> "=\r\n" <> escaped,
        byte_size(escaped)
      )
    end
  end

  @doc """
  Will render all headers according to the RFC2882 spec
  """
  def render_headers(headers, blacklist \\ [])

  def render_headers(map, blacklist) when is_map(map),
    do:
      Map.to_list(map)
      |> render_headers(blacklist)

  def render_headers(list, blacklist) when is_list(list) do
    Enum.reject(list, &Enum.member?(blacklist, elem(&1, 0)))
    |> do_render_headers()
    |> Enum.reverse()
    |> Enum.join("\r\n")
  end

  @doc """
  Builds a RFC2822 timestamp from an Erlang timestamp

  [RFC2822 3.3 - Date and Time Specification](https://tools.ietf.org/html/rfc2822#section-3.3)

  This function always assumes the Erlang timestamp is in Universal time, not Local time
  """
  def timestamp_from_erl({{year, month, day} = date, {hour, minute, second}}) do
    day_name = Enum.at(@days, :calendar.day_of_the_week(date) - 1)
    month_name = Enum.at(@months, month - 1)

    date_part = "#{day_name}, #{day} #{month_name} #{year}"
    time_part = "#{pad(hour)}:#{pad(minute)}:#{pad(second)}"

    date_part <> " " <> time_part <> " +0000"
  end

  defp pad(num),
    do:
      num
      |> Integer.to_string()
      |> String.pad_leading(2, "0")

  defp do_render_headers([]), do: []
  defp do_render_headers([{_key, nil} | headers]), do: do_render_headers(headers)
  defp do_render_headers([{_key, []} | headers]), do: do_render_headers(headers)

  defp do_render_headers([{key, value} | headers]) when is_binary(value) do
    if String.trim(value) == "" do
      do_render_headers(headers)
    else
      [render_header(key, value) | do_render_headers(headers)]
    end
  end

  defp do_render_headers([{key, value} | headers]) do
    [render_header(key, value) | do_render_headers(headers)]
  end

  defp reorganize(%Mail.Message{multipart: true} = message) do
    content_type = Mail.Message.get_content_type(message)

    if Mail.Message.has_attachment?(message) do
      text_parts =
        Enum.filter(message.parts, &alternative_body_part?/1)
        |> Enum.sort(&(&1 > &2))

      content_type = List.replace_at(content_type, 0, "multipart/mixed")
      message = Mail.Message.put_content_type(message, content_type)

      if Enum.any?(text_parts) do
        message = Enum.reduce(text_parts, message, &Mail.Message.delete_part(&2, &1))

        mixed_part =
          Mail.build_multipart()
          |> Mail.Message.put_content_type("multipart/alternative")

        mixed_part = Enum.reduce(text_parts, mixed_part, &Mail.Message.put_part(&2, &1))
        put_in(message.parts, List.insert_at(message.parts, 0, mixed_part))
      else
        message
      end
    else
      content_type = List.replace_at(content_type, 0, "multipart/alternative")
      Mail.Message.put_content_type(message, content_type)
    end
  end

  defp encode(body, message) do
    Mail.Encoder.encode(body, Mail.Message.get_header(message, "content-transfer-encoding"))
  end

  defp alternative_body_part?(part) do
    match_content_type?(part, ~r/text\/(plain|html)/) and not Mail.Message.is_attachment?(part)
  end

  defp maybe_put_utf8_charset(%Mail.Message{} = message) do
    if needs_utf8_charset?(message) do
      content_type =
        message
        |> Mail.Message.get_content_type()
        |> Mail.Proplist.put("charset", "UTF-8")

      Mail.Message.put_content_type(message, content_type)
    else
      message
    end
  end

  defp needs_utf8_charset?(%Mail.Message{body: body} = message) when is_binary(body) do
    text_part?(message) and has_non_ascii_byte?(body) and
      not content_type_has_param?(message, "charset")
  end

  defp needs_utf8_charset?(_message), do: false

  defp text_part?(message), do: match_content_type?(message, ~r/text\/(plain|html)/)

  defp content_type_has_param?(message, param) do
    message
    |> Mail.Message.get_content_type()
    |> Enum.any?(fn
      {key, _value} -> to_string(key) == param
      _value -> false
    end)
  end

  defp has_non_ascii_byte?(<<>>), do: false
  defp has_non_ascii_byte?(<<byte, _rest::binary>>) when byte > 127, do: true
  defp has_non_ascii_byte?(<<_byte, rest::binary>>), do: has_non_ascii_byte?(rest)
end
