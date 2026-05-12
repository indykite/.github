//
// DO NOT EDIT!!!
// Managed by GitHub Actions
//
export default {
  extends: ["@commitlint/config-conventional"],
  defaultIgnores: false,
  failOnWarnings: true,
  rules: {
    "body-max-line-length": [2, "always", 72],
    "header-max-length": [2, "always", 72],
    "subject-max-length": [2, "always", 50],
    "subject-case": [2, "never", ["sentence-case", "start-case", "pascal-case"]],
    "subject-full-stop": [2, "never", "."],
    "type-enum": [
      2,
      "always",
      ["build", "chore", "ci", "docs", "feat", "fix", "perf", "refactor", "revert", "style", "test"],
    ],
    "forbidden-characters": [2, "always"],
    "scope-enum": [
      2,
      "always",
      [
        "logging",
        "services",
        "docs",
        "dependencies",
        "deps",
        "authn",
        "authz",
        "api",
        "pkg",
        "proto",
        "cypher",
        "schema",
        "test",
        "master",
      ],
    ],
  },
  plugins: [
    "commitlint-plugin-function-rules",
    {
      rules: {
        "forbidden-characters": ({ header, body, footer }) => {
          let regex = /['`"]/;
          if (regex.test(header ?? "") || regex.test(body ?? "") || regex.test(footer ?? "")) {
            let allow_update = /Merge branch '.*' into/;
            if (allow_update.test(header)) {
              return [true];
            }
            return [false, "please, avoid special characters like [' \" `]"];
          }
          return [true];
        },
        },
    },
  ],
};
