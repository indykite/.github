//
// shareable config across org's repos, used both by 'pre-commit' and GitHub Actions
//
// https://commitlint.js.org/reference/configuration.html#configuration

const actor = process.env.GITHUB_ACTOR || "";
const releaseBotName = process.env.RELEASE_BOT || "";

async function isBotCommit(message) {
  return (
    message.includes("Signed-off-by: dependabot[bot]") ||
    (message.startsWith("chore(deps): update") && actor === "renovate[bot]") ||
    (message.startsWith("chore(master): release") && actor == releaseBotName)
  );
}

export default {
  // https://github.com/conventional-changelog/commitlint/blob/master/%40commitlint/config-conventional/src/index.ts
  extends: ["@commitlint/config-conventional"],
  defaultIgnores: false,
  failOnWarnings: true,
  ignores: [(message) => isBotCommit(message)],

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
      // Based on documentation, we can have only 1 local plugin.
      // But it can implement multiple rules if needed.
      // https://commitlint.js.org/#/reference-plugins?id=local-plugins
      rules: {
        "forbidden-characters": ({ header, body, footer }) => {
          let regex = /['`"]/;
          // Do not use raw instead of header+body+footer as raw contains also comments
          if (regex.test(header ?? "") || regex.test(body ?? "") || regex.test(footer ?? "")) {
            // Allow "update branch" for the PR
            let allow_update = /Merge branch '.*' into/; // Github's commit message
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
