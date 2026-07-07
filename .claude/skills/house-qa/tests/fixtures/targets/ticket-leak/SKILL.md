---
name: ticket-leak-fixture
description: Fixture artifact for the ticket-id-leak check — carries a ticket reference that should never ship in a public artifact.
---

# /ticket-leak-fixture

This step was added to close out LEX-302 and should not have shipped this way —
ticket IDs belong in PR bodies and commit trailers, never in the artifact body
itself (publishing-workflow.md).

## Identity

A minimal fixture skill used only by house-qa's test suite.
