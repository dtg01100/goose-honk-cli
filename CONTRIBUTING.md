# Contributing to gander

Thanks for helping improve gander. Contributions are welcome for bug fixes,
documentation, portability, and test coverage.

## Before opening a pull request

1. Keep the command-line behavior and documented key bindings compatible.
2. Avoid introducing a new runtime dependency unless it is documented and
   covered by the test setup.
3. Do not commit local session data, SQLite databases, exported session JSON,
   credentials, or machine-specific paths.
4. Run the checks below before requesting review.

## Development setup

Gander has no build step. Install Bash 4+, jq, sqlite3, and ShellCheck. The smoke
test uses a temporary fake `goose` executable and does not need a live session
database.

## Checks

```sh
make check
make test
```

Or run the commands directly:

```sh
bash -n gander install.sh lib/*.sh tests/*.sh
shellcheck -s bash -x gander install.sh lib/*.sh tests/*.sh
./tests/smoke.sh
```

## Guidelines

- Keep the main entrypoint and library scripts valid Bash 4 code.
- Quote shell expansions and pass user-controlled values as arguments rather
  than interpolating them into source text.
- Add or update a smoke-test case for changed behavior.
- Keep documentation, `--help` output, and the implementation in agreement.
- Use descriptive commit messages and explain any compatibility tradeoff.

## Pull requests

Please include:

- the problem being solved;
- the approach and relevant implementation details;
- validation commands and results;
- documentation changes for user-visible behavior.

By contributing, you agree that your contribution is licensed under the
project’s [MIT license](LICENSE).
