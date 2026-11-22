# Notes for Claude

## Contribution workflow

Claude contributes to this repository as an external contributor, through the GitHub account `v-claude-gh` and its fork `v-claude-gh/ansible-prod-srv`. The account has no write access to `Gu35t09/ansible-prod-srv`, on purpose.

1. Work in the fork. If the session only has `Gu35t09/ansible-prod-srv`, attach the fork with `add_repo` (owner `v-claude-gh`, access `push`).
2. Before starting, bring the fork's `main` up to date with upstream: add `https://github.com/Gu35t09/ansible-prod-srv.git` as the `upstream` remote, fetch `main` with a depth (e.g. `--depth=50`), fast-forward the fork's `main` to `upstream/main` and push it to `origin`.
3. Make the change on a new branch `claude/<short-description>` created from that `main`, commit with a message that can serve as the pull request's title and description, and push the branch to the fork.
4. Do not try to open the pull request: this session's proxy allows the GitHub API only on repositories attached with push access, so creating a PR on `Gu35t09/ansible-prod-srv` is refused. Give the owner the compare link instead, and they open the PR:
   `https://github.com/Gu35t09/ansible-prod-srv/compare/main...v-claude-gh:ansible-prod-srv:<branch>`
5. To check whether a PR was merged, fetch `upstream/main` and look for the branch's commit (`git merge-base --is-ancestor <commit> upstream/main`). Then fast-forward the fork's `main` again.

Old branches on the fork can stay; there is no need to delete them.

## Repository rules

- Never commit `inventory/group_vars/prod_servers/vault.yml` or any vault password file; `.githooks/pre-commit` refuses an unencrypted vault.
- Keep the README's layout tree and role table in step with the roles.
