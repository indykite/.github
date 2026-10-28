<!--
DO NOT EDIT!!!
Managed by GitHub Actions
-->
# docker-build action

GitHub action for building Docker images.

Currently tailored to AI/ML needs.

## Trivy image notifications

When enabling `trivy-scan`, pass notification inputs to `docker-build`; the action
forwards them to `trivy` and `trivy-notify`. Registry credentials alone do not
authenticate Slack, Jira, or suppression PR creation.

```yaml
with:
  trivy-scan: "1"
  slack-bot-token: ${{ secrets.SLACK_BOT_TOKEN }}
  jira-api-token: ${{ secrets.JIRA_API_TOKEN }}
  jira-cloud-id: ${{ secrets.JIRA_CLOUD_ID }}
  jira-watchers: ${{ secrets.TRIVY_JIRA_WATCHERS }}
  github-app-client-id: ${{ vars.IK_CODE_WRITER_CLIENT_ID }}
  github-app-private-key: ${{ secrets.IK_CODE_WRITER_PEM }}
```

These are action inputs, not Docker build arguments or BuildKit secrets. A missing
Slack token produces a warning and skips Slack notification without blocking Jira
or suppression handling. Fork pull requests do not receive repository secrets.

In order to run GitHub actions from private repositories, these repositories [need to be configured in a specific way](https://docs.github.com/en/enterprise-cloud@latest/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#allowing-access-to-components-in-a-private-repository):

- On GitHub, navigate to the main page of the private repository.
- Under your repository name, click `Settings`.
- In the left sidebar, click `Actions`, then click `General`.
- Under Access, choose: Accessible from repositories in the `ORGANIZATION NAME` organization - Workflows in other repositories that are part of the `ORGANIZATION NAME` organization can access the actions and reusable workflows in this repository. Access is allowed only from private repositories.
- It's expected that the `Dockerfile` will contain instructions to retrieve the predefined secrets, such as:

    ```dockerfile
  # Environment variables for private IndyKite pypi repo in Pipfile
  RUN --mount=type=secret,id=pypi-repo-indykite-username,env=USERNAME \
      --mount=type=secret,id=pypi-repo-indykite-password,env=PASSWORD \
      PIPENV_VENV_IN_PROJECT=1 pipenv install --deploy
    ```
