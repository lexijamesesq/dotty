# Tool-B

Small CLI utility for reformatting Widget-console exports into CSV.

## Install

```
pip install tool-b
```

## Usage

```
tool-b convert export.json --out data.csv
```

## Options

| Flag | Meaning |
|---|---|
| `--out` | Output path |
| `--strict` | Fail on schema mismatch |

## Notes

Reads stdin if no file is given.

## License

MIT
