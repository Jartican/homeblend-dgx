# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository. Do not open
a public issue containing a credential, endpoint, personal identifier, private
deployment detail, transcript, audio sample, or exploit proof.

## Security boundary

The public repository contains reusable source and fictional configuration
only. A deployment must keep credentials outside Git, require application
authentication in addition to tailnet identity, retain no raw audio, and block
sensitive persistence until encrypted storage and restore testing pass.

The compatibility voice mode is a migration aid, not a production mode. Public
defaults remain fail-closed and require a per-client credential registry.
