# Sample File Convention

Files matching `*.sample.md` are tracked templates for GitHub consumers. They ship with public repos so consumers know what config to create.

## Rules

- **Never read `*.sample.md` for project context.** The real file (e.g., `CLAUDE.md`) is always the authoritative source.
- **Never edit `*.sample.md` in place of the real config.** If you need to change project configuration, edit the real file.
- **When editing config in the real file, consider if the sample needs updating.** New config fields, renamed sections, or removed fields may need to be reflected in the sample for consumers. Flag this to the user rather than silently updating.
- **`*.sample.md` files use placeholders** (`TODO:`, `path/to/your/...`, `YOUR_VALUE_HERE`) where personal or org-specific values belong. These are never filled in — that's what the real file is for.
