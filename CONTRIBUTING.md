# Contributing

Using [pre-commit hooks](https://pre-commit.com/) ensures that code is automatically checked for formatting, linting, or other issues before it is committed,
helping maintain code quality and consistency across the team. It catches common problems early and enforces project standards efficiently.

To install the hooks, run:

```sh
pre-commit install --install-hooks
# optionally, to automate `git pull` & deletion of stale branches
pre-commit install -t post-checkout
```

Some of the hooks' prerequisites get provisioned automatically. Some, i.e. of `language: system` type, must be installed manually. Verify [.pre-commit-config.yaml](.pre-commit-config.yaml) for the exact list, e.g.:

```sh
brew install yamllint markdownlint-cli2 shellcheck ...
```

At any time, the checks against **_ALL_** files in the repository can be executed via:

```sh
pre-commit run -a
```

## Git Transport Protocol

There are certain pieces of code referencing to org's repositories using either SSH or HTTPS. Depending on personal preference it is easy to override those by executing either or:

- enforcing SSH

  ```sh
  git config --global url.ssh://git@github.com/indykite/.insteadOf https://github.com/indykite/
  ```

- enforcing HTTPS

  ```sh
  git config --global url.https://github.com/indykite/.insteadOf ssh://git@github.com/indykite/
  ```
