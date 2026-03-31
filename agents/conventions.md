# Implementation And Testing

- keep modules under the `Bamboo.GmailAdapter` namespace.
- let `mix format` control layout instead of hand-formatting around it.
- add or update `*_test.exs` files beside the behavior you change.
- write regression coverage for bug fixes.
- keep test names descriptive, for example `test "invalid configuration raises ConfigError" do`.
- if you change public behavior or docs examples, update the doctest in `test/bamboo_gmail_test.exs` and any related docs.
