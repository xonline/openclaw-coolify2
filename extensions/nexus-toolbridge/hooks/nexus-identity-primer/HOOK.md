---
name: "nexus-identity-primer"
description: "Prime new OpenClaw sessions with Nexus user identity context"
metadata: {"openclaw":{"events":["command:new"]}}
---

# Nexus Identity Primer

Loads the user's Nexus identity snapshot on `/new` and injects a concise context block
into the new session so the assistant starts with user-specific identity context.
