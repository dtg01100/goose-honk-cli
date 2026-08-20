# Upstream integration path

## Status

This repository is an independent, third-party companion to goose. It is
not affiliated with, endorsed by, supported by, or distributed as part of the
official goose project, AAIF, or Block. The current command is a separate
composable CLI and must not be presented as an official goose extension.

## Why a companion project exists

The current implementation is intentionally a small Bash/fzf shim around the
public goose CLI and local goose session data. That makes it:

- easy to install without replacing the goose binary;
- independently versioned and testable;
- safe to experiment with before changing the official Rust codebase; and
- useful as a reference for the desired user experience.

The official goose repository is written in Rust and is Apache-2.0 licensed. Its
maintainers have stated that the CLI should remain composable rather than embed
one particular fuzzy-picker workflow. See the official discussion in
[goose issue #9915](https://github.com/aaif-goose/goose/issues/9915), which was
closed as not planned.

## Recommended upstream path

If maintainers want this functionality in goose proper, the clean path is:

1. Open a feature request or discussion in the
   [aaif-goose/goose repository](https://github.com/aaif-goose/goose/issues/new/choose).
2. Describe the user problem, target users, desired commands, and compatibility
   expectations without assuming that a Bash implementation will be accepted.
3. Wait for the issue to reach **Ready** in the
   [goose Issues board](https://github.com/orgs/aaif-goose/projects/1). The
   [official contribution guide](https://github.com/aaif-goose/goose/blob/main/CONTRIBUTING.md)
   requires external pull requests to link a Ready issue and stay within its
   agreed design.
4. If accepted, implement the feature in the official Rust CLI, probably in
   crates/goose-cli, and reuse the existing SessionManager rather than the
   private SQLite schema where possible.
5. Coordinate naming, compatibility, license/attribution, and a transition plan
   before retiring or deprecating this companion.

## Likely integration shape

The companion currently demonstrates this flow:

```sh
goose session list --format json
goose session --resume --session-id <id>
```

A native upstream implementation could expose an interactive selector through
the existing session command, add a dedicated session-list picker command, or
integrate selection into the existing terminal UI. The maintainers should
decide which surface fits the official CLI.

A goose MCP extension is probably not the right home for a terminal picker:
extensions provide tools to the agent, while this feature is a local human
interface. An ACP client could be another integration option, but it should
not be assumed without maintainer direction.

## Compatibility principles

- Prefer stable public CLI interfaces such as `goose session list --format json`,
  `goose session --resume --session-id`, and `goose info`.
- Do not make the wrapper depend on private SQLite schema details when a public
  API is available.
- Preserve user privacy; do not add telemetry or transmit session content.
- Keep the destructive delete action explicit and confirmed.
- Document the minimum tested goose version and avoid silently changing
  resume/fork/export semantics.

## License and attribution

This companion is MIT-licensed. goose is Apache-2.0 licensed. If code is later
ported upstream, retain the applicable copyright and license notices and
confirm the contribution's licensing with the goose maintainers. The official
governance documentation says that code contributions are generally made
under the goose Apache-2.0 project license.

## Official links

- [goose repository](https://github.com/aaif-goose/goose)
- [goose contribution guide](https://github.com/aaif-goose/goose/blob/main/CONTRIBUTING.md)
- [goose governance](https://github.com/aaif-goose/goose/blob/main/GOVERNANCE.md)
- [goose CLI command documentation](https://goose-docs.ai/docs/guides/goose-cli-commands)
- [goose issue #9915](https://github.com/aaif-goose/goose/issues/9915)
- [goose custom distributions](https://github.com/aaif-goose/goose/blob/main/CUSTOM_DISTROS.md)
