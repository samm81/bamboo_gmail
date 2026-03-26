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

    subject_line = header_line(rendered, "Subject")

    assert subject_line == RFC2822.render_header("subject", @unicode_subject)
    assert subject_line =~ "=?UTF-8?Q?"
    assert subject_line =~ "=E2=80=93"
    refute subject_line =~ @unicode_subject
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
    rendered
    |> String.split("\r\n\r\n", parts: 2)
    |> hd()
    |> String.split("\r\n")
    |> Enum.find(&String.starts_with?(&1, "#{header_name}: "))
  end
end
