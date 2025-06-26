// https://commitlint.js.org/reference/configuration.html#configuration
export default {
  // https://github.com/conventional-changelog/commitlint/blob/master/%40commitlint/config-conventional/src/index.ts
  extends: ["@commitlint/config-conventional"],
  defaultIgnores: false,
  failOnWarnings: true, // strict mode, fail on warnings - FIXME: doesn't work via config?

  rules: {
    //   0 - Disabled, 1 - Warning, 2 - Error
    "body-max-line-length": [2, "always", 72],
    "header-max-length": [2, "always", 72],
    "subject-max-length": [2, "always", 50],
    // override 'config-conventional', allow upper case for abbreviations
    "subject-case": [2, "never", ["sentence-case", "start-case", "pascal-case"]],
    "subject-full-stop": [2, "never", "."],
    "type-enum": [
      2,
      "always",
      ["build", "chore", "ci", "docs", "feat", "fix", "perf", "refactor", "revert", "style", "test"],
    ],
    "scope-enum": [0, "always", [],],
  },
};
