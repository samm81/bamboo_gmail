# Project Structure

This library is centered on a single Bamboo adapter implementation.

## Module Ownership

- `lib/bamboo/adapters/gmail_adapter.ex` owns the public adapter API, config handling, request assembly, and delivery flow.
- `lib/bamboo/adapters/gmail_adapter/errors.ex` defines adapter-specific exception types.
- `lib/bamboo/adapters/gmail_adapter/rfc_2822.ex` owns MIME rendering plus address and header shaping.
- `config/config.exs` holds shared project config.
- `test/` mirrors the library surface with `bamboo_gmail_test.exs`, `errors_test.exs`, and `rfc_2822_test.exs`.

## Change Placement

- prefer the narrowest file that already owns the behavior you are changing.
- keep public entry points in `Bamboo.GmailAdapter`; split helpers out privately when message assembly or request handling grows.
