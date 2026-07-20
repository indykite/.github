#
# DO NOT EDIT!!!
# Managed by GitHub Actions
#
# docker-build action

GitHub action for building Docker images.

Currently tailored to AI/ML needs.

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
