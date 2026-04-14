# Contributing to THL SQL

Thanks for your interest in improving THL SQL.

## Before You Start

- Check existing issues and pull requests to avoid duplicate work.
- Open an issue first for major changes.
- Keep security-sensitive details out of public issues.

## Development Guidelines

- Keep changes small and focused.
- Do not commit secrets, credentials, or private keys.
- Use environment variables and `*.example` files for configuration.
- Preserve compatibility with supported Linux distro families.

## Pull Request Checklist

- Explain the problem and the proposed solution.
- Include clear validation steps.
- Update documentation when behavior or setup changes.
- Confirm repository safety checks pass:

```bash
bash server/check_repo_safety.sh
```

## Commit Style

- Use descriptive messages in present tense.
- Recommended prefixes: `feat:`, `fix:`, `docs:`, `chore:`, `ci:`.

## Code of Conduct

By participating in this project, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
