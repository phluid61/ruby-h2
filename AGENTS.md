# Agent Instructions

ruby-h2 is a pure Ruby implementation of the HTTP/2 protocol (RFC 7540),
including HPACK header compression (RFC 7541). It has no runtime gem
dependencies beyond Ruby's standard library (plus `openssl` and `threadpuddle`).

## Repository layout

- `lib/ruby-h2/` — the library itself, under the `RUBYH2` module
- `test/` — unit tests using `test/unit` (Ruby's built-in framework)
- `demo-site.rb` — demo HTTP/2 server (uses `lib/ruby-h2/application.rb`)
- `demo-client.rb` — demo client that exercises the server
- `client.rb` — general-purpose HTTP/2 client

## Key architecture

Start in `lib/ruby-h2/http-agent.rb`; it is the core connection handler.
`HTTPServerAgent` and `HTTPClientAgent` (in their respective files) subclass
it. Read those three files to understand the protocol state machine.

Other important subsystems:

- **Framing** — `frame.rb`, `frame-types.rb`, `frame-serialiser.rb`,
  `frame-deserialiser.rb`, and `headers-hook.rb` (reassembles
  HEADERS+CONTINUATION sequences)
- **HPACK** — `hpack.rb` (tables and encode/decode), `hpack/encoding.rb`
  (integer and string primitives), `hpack/huffman-codes.rb` (Huffman codec)
- **HTTP model** — `http-message.rb` (base), `http-request.rb`,
  `http-response.rb`
- **Stream lifecycle** — `stream.rb` (per-stream state and headers),
  `header.rb` (multi-value header representation)
- **Prioritisation** — `priority-tree.rb`
- **Settings** — `settings.rb` (SETTINGS frame codec, including experimental
  `ACCEPT_GZIPPED_DATA`)
- **Errors** — `errors.rb` (error codes, `ConnectionError`, `StreamError`,
  `SemanticError`)
- **Demo server glue** — `application.rb` (Sinatra-like DSL, TLS setup)

## Conventions

- All library source files begin with `# encoding: BINARY` because HTTP/2
  is a binary protocol; strings are manipulated at the byte level. Preserve
  this magic comment in every file under `lib/`.
- Vim modelines (`# vim: ts=2 sts=2 sw=2 expandtab`) appear at the top of
  most files. Preserve them when editing, but do not add them to new files
  unless the surrounding files have them.
- Indentation is 2 spaces; no tabs in library code. Test files use tabs.
- The project has no Gemfile, gemspec, or Rakefile. Do not introduce a build
  system or package manager configuration unless asked.
- There are several `# FIXME` and `# TODO` markers in the source. These are
  known; do not "fix" them unless specifically asked.

## Testing

Tests live in `test/` and use Ruby's built-in `test/unit`. Run them with:

```
ruby test/test_encoding.rb
ruby test/test_huffman_codes.rb
```

There is no single command to run all tests. Run each test file individually.
Test helper utilities are in `test/helpers.rb`.

## Branching model

This project follows git-flow. The integration branch is called
`development` (not `develop`).

- **`main`** — production-ready releases.
- **`development`** — integration branch for the next release. This is the
  default branch.
- **`feature/*`** — branched from `development`, merged back into
  `development`.
- **`release/*`** — branched from `development`, merged into both `main`
  and `development`.
- **`hotfix/*`** — branched from `main`, merged into both `main` and
  `development`.

When creating branches or targeting merges, use `development` as the base
branch unless working on a hotfix.

## GitHub Actions

- `.github/workflows/update-pages.yml` triggers on pushes to `main`
  when `README.md`, `LICENSE`, or `code_of_conduct.md` change. It syncs
  those files from `development` to the `gh-pages` branch and rebuilds
  `index.html` and `code_of_conduct.html` using an inline Ruby script
  (commonmarker). The `gh-pages` branch has its own Gemfile for this.

## Experimental features

Some frame types and settings are non-standard experiments:

- `GZIPPED_DATA` (frame type `0xf0`) and `DROPPED_FRAME` (`0xf1`) in
  `frame-types.rb`
- `ACCEPT_GZIPPED_DATA` (setting `0xf000`) in `settings.rb`

These are intentional; do not remove or flag them as errors.

## Licence

ISC — see `LICENSE`.
