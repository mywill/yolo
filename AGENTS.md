# Notes for Agents

## References

1. `SPEC.md` — contract for flags, mounts, env vars, `.yolo/` system.
2. `README.md` — user tutorial.
3. `tests/yolo.bats` — executable spec.

On disagreement, the test suite wins.

## Test and lint

```
bats tests/
shellcheck bin/yolo setup-yolo.sh images/entrypoint.sh
```

Both run in CI (`.github/workflows/ci.yml`).

## `.yolo/` is the project-environment contract

Any change to `.yolo/root-setup.sh` / `.yolo/user-setup.sh` semantics
(locations, `USER` stage, working directory, hash formula, base image)
requires coordinated edits to:

- `bin/yolo` (`resolve_image`),
- `SPEC.md` §4,
- `resolve_image:*` tests in `tests/yolo.bats`.

## Recipe templates

Canonical source: `images/examples/<lang>/`. `setup-yolo.sh` copies these
into the installed skill at `~/.claude/skills/yolo/recipes/<lang>/` (and
`~/.agents/skills/yolo/recipes/`) so agents can read them without needing
the yolo repo on disk. Updated recipes only reach existing installs after
`setup-yolo.sh` re-runs — flag this in any commit that touches the
templates.

## House style

`bin/yolo` is one bash file. The test suite extracts functions via
`awk` parsing that requires:

```bash
name() {
    ...
}
```

`name() {` opens, bare `}` closes. Don't collapse to one line, indent the
closing brace, or fuse multiple functions — `extract_function` in
`tests/yolo.bats:29–35` will silently miss them.

`.shellcheckrc` documents intentional disables.

## `config.example` mirrors `print_config_template`

`config.example` is reference documentation; the template that actually
lands in `.git/yolo/config` on first run (and via `yolo --install-config`)
is `print_config_template` inside `bin/yolo`. Any change to one must be
mirrored to the other.
