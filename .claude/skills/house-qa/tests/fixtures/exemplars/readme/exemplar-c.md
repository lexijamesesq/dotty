# Tool-C

Wraps Product-D's export API in a single-binary CLI.

## Install

Download the release binary for your platform from the releases page.

## Usage

```
tool-c pull --since 2026-01-01
tool-c push --dry-run
```

## Configuration

Set `TOOL_C_TOKEN` in your environment before running either command.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Auth failure |
| 2 | Network error |

## License

MIT
