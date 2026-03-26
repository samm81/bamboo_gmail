# Repository Guidelines

## Project Structure & Module Organization
This repository is a small Elixir library that provides a Bamboo adapter for Gmail. Core code lives in `lib/bamboo/adapters/`: `gmail_adapter.ex` is the public adapter, `gmail_adapter/errors.ex` defines exception types, and `gmail_adapter/rfc_2822.ex` handles message rendering. Shared project config is in `config/config.exs`. Tests live in `test/` and mirror the library surface with files such as `bamboo_gmail_test.exs`, `errors_test.exs`, and `rfc_2822_test.exs`.

## Build, Test, and Development Commands
- `mix deps.get`: install Hex dependencies.
- `mix compile`: compile the library and catch warnings early.
- `mix test`: run the ExUnit suite in `test/`.
- `mix format`: format `mix.exs` and all `config/`, `lib/`, and `test/` files using `.formatter.exs`.
- `mix docs`: build HexDocs locally because `ex_doc` is included for `:dev`.

Run the standard check before opening a PR: `mix format && mix test`.

## Coding Style & Naming Conventions
Use standard Elixir style with 2-space indentation and `snake_case` filenames. Keep module names under the existing `Bamboo.GmailAdapter` namespace. Prefer small private helpers for message assembly and request handling, but keep the public adapter API centered in `Bamboo.GmailAdapter`. Let `mix format` decide layout; do not hand-format around it.

## Testing Guidelines
The project uses ExUnit. Add or update `*_test.exs` files beside the behavior you change, and write regression tests for bug fixes. Keep test names descriptive, for example `test "invalid configuration raises ConfigError" do`. If you touch docs or public behavior, update doctest-backed examples where relevant and run `mix test`.

## Commit & Pull Request Guidelines
Recent history uses short subjects such as `UPDATE: change return signature to fit what bamboo expects`. Keep commit titles brief and imperative; include issue references when helpful. PRs should explain the behavior change, mention any Gmail or Bamboo integration impact, and include tests. Update `README.md` and this file when setup, commands, or contributor workflow changes.
When fixing an issue tracked in `TODO.txt`, update that entry's status and details before finishing the task.

## Security & Configuration Tips
Never commit service-account JSON, impersonated `sub` addresses, or other Gmail credentials. Follow the README pattern of loading secrets from environment variables or files, for example `{:system, "GCP_CREDENTIALS"}`.
