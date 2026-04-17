defmodule Bamboo.GmailAdapter.DocsCompatibilityTest do
  use ExUnit.Case, async: true

  test "ex_doc dependency supports current callback docs metadata" do
    ex_doc_version =
      :ex_doc
      |> Application.spec(:vsn)
      |> to_string()
      |> Version.parse!()

    assert Version.compare(ex_doc_version, Version.parse!("0.38.0")) != :lt
  end
end
