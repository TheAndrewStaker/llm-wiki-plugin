# Security policy

This software operates on private documents and can run git and lifecycle hooks, so reports involving
source disclosure, path traversal, prompt injection, unsafe hook execution, credential persistence,
symlink races, or unintended network writes are security-sensitive.

Use GitHub private vulnerability reporting when it is enabled for the public repository. Until then,
contact the maintainer privately through the address on the maintainer's GitHub profile. Do not open a
public issue containing exploits, secrets, private source material, absolute personal paths, or remote URLs
with embedded credentials. Include a synthetic reproducer, affected commit, and impact.

Only the latest release receives security fixes before 1.0. No response-time SLA is promised. Users should
keep raw-source repositories private, review staged material before committing, leave `auto_push` disabled
unless explicitly needed, and run agents with least-privilege filesystem/network access.
