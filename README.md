# TERMINAL.R4X

`TERMINAL.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.8`
- Image target: `/R4OS/SOFTWARE/TERMINAL/TERMINAL.R4X`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.


Working directory (0.78.67)
---------------------------
CWD is the calling process's canonical drive and directory, exposed through
the existing env_get/env_set functions. It is not stored a second time in
the environment block. env_set("CWD", value) requires an absolute drive path,
normalizes separators and dot segments, rejects embedded NUL, and confirms
that the target exists as a directory before publishing the process context.
Invalid, unavailable, non-directory or overlong targets leave the old context
intact. env_get returns the full drive-qualified path; a short output buffer
is unchanged. No public function, table layout or result constant is added.

Path snapshots and publication use the program-state owner. Filesystem work
runs before that owner is acquired; child admission copies the parent's
complete context. Only launches without a parent use the bootstrap drive's
initial directory. Terminal inherits CWD at startup and changes its prompt
only after env_set confirms a CD or drive switch. It does not rewrite CWD
when synchronizing ordinary environment values. Relative file operations,
redirection and child launches therefore share one context; a child's later
change remains private. CD C:relative uses the current C directory. Switching
to a different drive still selects its root. VOL without an operand uses
the confirmed current drive.

A short SMP4 guest checks same-named private files, TYPE/COPY/REN/DEL/MD/RD,
redirection, direct child and nested Terminal inheritance, failed directory
and drive changes, short CWD reads and VOL on two local volumes. R4OS and
Recovery carry the same correction; no broad shell or filesystem profile.
