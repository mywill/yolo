# Notes for Claude Code

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

## House style

`bin/yolo` is one bash file. The test suite extracts functions via
`awk` parsing that requires:

```bash
name() {
    ...
}
```

`name() {` opens, bare `}` closes. Don't collapse to one line, indent the
closing brace, or fuse multiple functions — `tests/yolo.bats:23–29` will
silently miss them.

`.shellcheckrc` documents intentional disables.
