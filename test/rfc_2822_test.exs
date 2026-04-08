defmodule Bamboo.GmailAdapter.RFC2822Test do
  use ExUnit.Case, async: true

  alias Bamboo.GmailAdapter.RFC2822

  @unicode_subject "Has GCSE Chemistry (AQA) – Atomic Structure & the Periodic Table (Topic 1) been useful so far?"

  test "matches upstream current mail header encoding for simple unicode subjects" do
    assert RFC2822.render_header("subject", "Café résumé") ==
             "Subject: =?UTF-8?Q?Caf=C3=A9 r=C3=A9sum=C3=A9?="
  end

  test "raw render encodes unicode subject headers" do
    rendered =
      %Mail.Message{}
      |> Mail.put_from("from@example.com")
      |> Mail.put_to("to@example.com")
      |> Mail.put_subject(@unicode_subject)
      |> Mail.put_text("body")
      |> RFC2822.render()

    subject_line = header_entry(rendered, "Subject")

    assert subject_line == RFC2822.render_header("subject", @unicode_subject)
    assert subject_line =~ "=?UTF-8?Q?"
    assert subject_line =~ "=E2=80=93"
    refute subject_line =~ @unicode_subject
  end

  test "folds long encoded subject headers onto continuation lines" do
    header = RFC2822.render_header("subject", @unicode_subject)
    lines = String.split(header, "\r\n")

    assert length(lines) > 1
    assert Enum.drop(lines, 1) |> Enum.all?(&String.starts_with?(&1, " "))
    assert Enum.all?(lines, &(byte_size(&1) <= 78))
    assert String.replace(header, "\r\n", "") =~ "?= =?UTF-8?Q?"
  end

  test "ascii subject headers remain plain" do
    subject = "Has GCSE Chemistry (AQA) - Atomic Structure & the Periodic Table (Topic 1)"

    rendered =
      %Mail.Message{}
      |> Mail.put_from("from@example.com")
      |> Mail.put_to("to@example.com")
      |> Mail.put_subject(subject)
      |> Mail.put_text("body")
      |> RFC2822.render()

    assert header_line(rendered, "Subject") == "Subject: #{subject}"
  end

  test "encodes non-ascii display names in address headers" do
    header = RFC2822.render_header("from", {"José – Example", "jose@example.com"})

    assert header =~ "From: =?UTF-8?Q?"
    assert header =~ "Jos=C3=A9"
    assert header =~ "=E2=80=93"
    assert header =~ "<jose@example.com>"
  end

  test "escapes quoted and backslashed display names in address headers" do
    header = RFC2822.render_header("to", {"A \\ \"Quoted\" User", "to@example.com"})

    assert header == ~S(To: "A \\ \"Quoted\" User" <to@example.com>)
  end

  test "rejects header injection in bare address headers" do
    assert_raise ArgumentError, ~r/is invalid/, fn ->
      RFC2822.render_header("to", "victim@example.com\r\nBcc: injected@example.com")
    end
  end

  test "rejects header injection in named address headers" do
    assert_raise ArgumentError, ~r/is invalid/, fn ->
      RFC2822.render_header("to", {"Victim", "victim@example.com\r\nBcc: injected@example.com"})
    end
  end

  test "rejects header injection in custom header names" do
    assert_raise ArgumentError, ~r/header name `X-Test\r\nBcc` is invalid/, fn ->
      RFC2822.render_header("X-Test\r\nBcc", "trace-123")
    end
  end

  test "rejects multipart boundary injection in rendered messages" do
    assert_raise ArgumentError,
                 ~r/boundary value `safe\r\nBcc: injected@example.com` is invalid/,
                 fn ->
                   Mail.build_multipart()
                   |> Mail.put_from("from@example.com")
                   |> Mail.put_to("to@example.com")
                   |> Mail.put_subject("subject")
                   |> Mail.put_text("body")
                   |> Mail.Message.put_boundary("safe\r\nBcc: injected@example.com")
                   |> RFC2822.render()
                 end
  end

  test "render omits bcc headers from the final message" do
    rendered =
      %Mail.Message{}
      |> Mail.put_from("from@example.com")
      |> Mail.put_to("to@example.com")
      |> Mail.put_bcc({"Hidden Recipient", "bcc@example.com"})
      |> Mail.put_subject("subject")
      |> Mail.put_text("body")
      |> RFC2822.render()

    assert header_line(rendered, "To") == "To: to@example.com"
    assert header_line(rendered, "Bcc") == nil
  end

  test "render collapses empty multipart messages into header-only output" do
    rendered =
      Mail.build_multipart()
      |> Mail.put_from("from@example.com")
      |> Mail.put_to("to@example.com")
      |> Mail.put_subject("subject")
      |> RFC2822.render()

    assert header_line(rendered, "To") == "To: to@example.com"
    assert header_line(rendered, "Subject") == "Subject: subject"
    assert header_line(rendered, "Mime-Version") == "Mime-Version: 1.0"
    refute rendered =~ "Content-Type: multipart/alternative"
    refute rendered =~ ~r/--[A-F0-9]{24}/
    assert String.ends_with?(rendered, "\r\n\r\n")
  end

  test "quotes ascii attachment filenames with special characters" do
    header =
      RFC2822.render_header("content-disposition", [
        "attachment",
        {"filename", "quarterly report (final).pdf"}
      ])

    assert header ==
             ~s|Content-Disposition: attachment; filename="quarterly report (final).pdf"|
  end

  test "encodes non-ascii attachment filenames with rfc2231 parameters" do
    rendered =
      Mail.Message.build_attachment({"résumé final.pdf", "data"})
      |> RFC2822.render_part()

    header = header_line(rendered, "Content-Disposition")

    assert header ==
             ~s|Content-Disposition: attachment; filename*=UTF-8''r%C3%A9sum%C3%A9%20final.pdf|

    refute header =~ "résumé final.pdf"
  end

  test "keeps text attachments outside multipart alternative body section" do
    rendered =
      Mail.build_multipart()
      |> Mail.put_from("from@example.com")
      |> Mail.put_to("to@example.com")
      |> Mail.put_subject("subject")
      |> Mail.put_text("body")
      |> Mail.put_attachment({"notes.txt", "attachment body"})
      |> RFC2822.render()

    outer_boundary = boundary_for(rendered, "multipart/mixed")

    [_, alternative_part, attachment_part] =
      String.split(rendered, "--#{outer_boundary}\r\n", parts: 3)

    refute alternative_part =~ "Content-Disposition: attachment; filename=notes.txt"

    attachment_headers =
      attachment_part
      |> String.split("\r\n\r\n", parts: 2)
      |> hd()

    assert attachment_headers =~ "Content-Disposition: attachment; filename=notes.txt"
  end

  test "keeps inline cid attachments inside multipart related and regular attachments outside it" do
    rendered =
      Mail.build_multipart()
      |> Mail.put_from("from@example.com")
      |> Mail.put_to("to@example.com")
      |> Mail.put_subject("subject")
      |> Mail.put_html(~s(<img src="cid:logo-123" alt="logo" />))
      |> Mail.Message.put_part(inline_attachment_part())
      |> Mail.put_attachment({"notes.txt", "attachment body"})
      |> RFC2822.render()

    outer_boundary = boundary_for(rendered, "multipart/mixed")

    [_, related_part, attachment_part] =
      String.split(rendered, "--#{outer_boundary}\r\n", parts: 3)

    assert related_part =~ "Content-Type: multipart/related"
    assert related_part =~ "Content-Disposition: inline; filename=logo.png"
    refute related_part =~ "Content-Disposition: attachment; filename=notes.txt"

    attachment_headers =
      attachment_part
      |> String.split("\r\n\r\n", parts: 2)
      |> hd()

    assert attachment_headers =~ "Content-Disposition: attachment; filename=notes.txt"
  end

  test "adds utf-8 charset to non-ascii text bodies" do
    rendered =
      %Mail.Message{}
      |> Mail.put_from("from@example.com")
      |> Mail.put_to("to@example.com")
      |> Mail.put_subject("subject")
      |> Mail.put_text("café body")
      |> RFC2822.render()

    assert header_line(rendered, "Content-Type") == "Content-Type: text/plain; charset=UTF-8"
  end

  test "adds utf-8 charset to non-ascii html bodies" do
    rendered =
      %Mail.Message{}
      |> Mail.put_from("from@example.com")
      |> Mail.put_to("to@example.com")
      |> Mail.put_subject("subject")
      |> Mail.put_html("<p>café body</p>")
      |> RFC2822.render()

    assert header_line(rendered, "Content-Type") == "Content-Type: text/html; charset=UTF-8"
  end

  test "keeps ascii text bodies without a charset parameter" do
    rendered =
      %Mail.Message{}
      |> Mail.put_from("from@example.com")
      |> Mail.put_to("to@example.com")
      |> Mail.put_subject("subject")
      |> Mail.put_text("plain body")
      |> RFC2822.render()

    assert header_line(rendered, "Content-Type") == "Content-Type: text/plain"
  end

  defp header_line(rendered, header_name) do
    case header_entry(rendered, header_name) do
      nil -> nil
      header -> header |> String.split("\r\n") |> hd()
    end
  end

  defp header_entry(rendered, header_name) do
    rendered
    |> String.split("\r\n\r\n", parts: 2)
    |> hd()
    |> String.split("\r\n")
    |> Enum.reduce_while([], fn line, acc ->
      cond do
        acc == [] and String.starts_with?(line, "#{header_name}:") ->
          {:cont, [line]}

        acc != [] and String.starts_with?(line, [" ", "\t"]) ->
          {:cont, [line | acc]}

        acc != [] ->
          {:halt, acc}

        true ->
          {:cont, acc}
      end
    end)
    |> case do
      [] -> nil
      lines -> lines |> Enum.reverse() |> Enum.join("\r\n")
    end
  end

  defp boundary_for(rendered, content_type) do
    regex = ~r/Content-Type: #{Regex.escape(content_type)}; boundary="([^"]+)"/
    [_, boundary] = Regex.run(regex, rendered)
    boundary
  end

  defp inline_attachment_part do
    Mail.Message.build_attachment({"logo.png", "data"})
    |> Mail.Message.put_content_type("image/webp")
    |> Mail.Message.put_header(:content_id, "<logo-123>")
    |> Mail.Message.put_header(:content_disposition, ["inline", {"filename", "logo.png"}])
  end
end
