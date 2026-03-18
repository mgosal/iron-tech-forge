# Anti-Gravity Custom Rules

These rules apply to any Anti-Gravity AI chat session that is working within the `anti-gravity-forge` repository.

## Branching Strategy for Manual Work

When the user asks the AI to manually modify the Forge's infrastructure (such as editing Bash scripts in `scripts/`, YAML configuration files in `.antigravity/`, or GitHub workflows), the AI **MUST NOT** commit directly to the `main` branch.

Instead, the AI must follow this workflow:
1. Create a new branch off `main` using the appropriate Conventional Commits prefix:
   - `chore/<description>` for housekeeping, config updates, script tweaks, or `.gitignore` changes.
   - `feat/<description>` for net-new features or significant agent logic additions.
   - `fix/<description>` for bug fixes in the manual scripts.
2. Make the requested changes.
3. Commit the changes using the same Conventional Commits format prefix in the commit message.
4. Push the branch to the remote repository.
5. Create a GitHub Pull Request for the user to review.

*Note: The automated Forge agents running via IronTech use the `ag/issue-*` branch prefix. The rules above apply ONLY to the human-AI pair programming chat session.*
