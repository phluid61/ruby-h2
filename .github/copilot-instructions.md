# Copilot Instructions

## Language and encoding

- This is a pure Ruby project targeting Ruby 3.x. There are no gem
  dependencies to manage (no Gemfile or gemspec).
- All library files under `lib/` must begin with `# encoding: BINARY`.
  HTTP/2 is a binary protocol and the code relies on binary string semantics
  throughout.
- Use `String.new.b` or `.b` to create/coerce binary strings, not
  `force_encoding`.

## Style

- 2-space indentation (spaces, not tabs) in library code. Test files use
  tabs — match the existing style of whichever file you are editing.
- Prefer Ruby symbol-style hash keys (`:key => value`) over the newer
  `key: value` syntax, matching the existing codebase.
- Keep methods concise; the codebase favours short methods with minimal
  abstraction layers.

## Module structure

- All library classes and modules live under the `RUBYH2` namespace.
- Do not introduce new top-level classes or modules.

## Testing

- Use `test/unit` (Ruby's built-in test framework). Do not introduce RSpec,
  Minitest, or other test frameworks.
- Place new test files in `test/` and name them `test_*.rb`.
- Include `TestHelpers` from `test/helpers.rb` when writing tests.

## Things to preserve

- Vim modelines at the top of files — do not remove them.
- `# FIXME` / `# TODO` comments — these are known issues tracked in-source.
  Do not resolve them unless specifically asked.
- Experimental/non-standard frame types and settings (e.g. `GZIPPED_DATA`,
  `ACCEPT_GZIPPED_DATA`) are intentional.
