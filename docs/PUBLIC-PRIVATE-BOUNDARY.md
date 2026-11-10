# Public and private project boundary

HomeBlend uses one reusable public codebase and one private deployment overlay.
These are layers of the same system, not independent forks.

## Public codebase

The public repository may contain:

- application and service source;
- secure bootstrap code and schema migrations;
- generic architecture, protocol, and threat-model documentation;
- example configuration with invalid or fictional identifiers;
- synthetic tests and public benchmark inputs;
- CI, dependency, and release-safety checks.

It must not contain live hostnames, tailnet names, IP addresses, usernames,
device identifiers, client registries, signing identities, personal prompts,
locations, transcripts, audio, database contents, operational status, recovery
material, credentials, or private context.

## Private deployment overlay

The private overlay pins a reviewed public release and supplies inventory,
configuration, deployment checkpoints, device enrollment, and private
runbooks. Plaintext secrets still stay outside Git: use the iPhone Keychain,
root-owned DGX files, or an encrypted secrets manager. A private Git repository
is not itself a secrets manager.

## Release rule

Build public releases from the tracked-file allowlist in `public-release.json`.
Never publish by copying the private working tree and deleting files afterward.
Run both repository scanners before publishing, inspect the generated tree,
create a clean release commit, and verify the remote tree and CI result.
