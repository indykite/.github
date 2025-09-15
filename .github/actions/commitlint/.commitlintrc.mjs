//
// DO NOT EDIT!!!
// Managed by GitHub Action and synced from a private repo!
//
const actor = process.env.GITHUB_ACTOR || "";
const releaseBotName = process.env.RELEASE_BOT || "";
async function isBotCommit(message) {
  return (
    message.includes("Signed-off-by: dependabot[bot]") ||
    (message.startsWith("ci(sync): update GitHub Actions") && actor === "renovate[bot]") ||
    (message.startsWith("ci(deps): update") && actor === "renovate[bot]") ||
    (message.startsWith("test(deps): update") && actor === "renovate[bot]") ||
    (message.startsWith("chore(deps): update") && actor === "renovate[bot]") ||
    (message.startsWith("chore(deps): Pin dependencies") && actor === "renovate[bot]") ||
    (message.startsWith("chore(master): release") && actor == releaseBotName)
  );
}
export default {
  extends: ["@commitlint/config-conventional"],
  defaultIgnores: false,
  failOnWarnings: true,
  ignores: [(message) => isBotCommit(message)],
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
        "contains-jira-ticket": ({ header, body, footer }) => {
          if (isBotCommit(header)) {
            return [true];
          }
          let regex = /\bENG\-[0-9]{2,}\b/;
          if (regex.test(header)) {
            return [false, "Please, move your JIRA ticket into commit body, and do not include in header directly."];
          }
          if (regex.test(body) === false && regex.test(footer) === false) {
            return [
              false,
              "Your commit message is missing JIRA ticket. Consider adding it to commit body or ignore this error.",
            ];
          }
          return [true];
        },
      },
    },
  ],
};
