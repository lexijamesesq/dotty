# Tests

- **Prove a coverage gap before adding a test.** Inspect existing coverage and identify the meaningful behavior or demonstrated bug that is unprotected. If there is no gap, add no test. Explain briefly in the normal handoff—no additional approval document or automated policy.
- **Prefer extending existing behavioral tests.** Exercise real interfaces between components where relevant. Mock external dependencies only as needed; do not recreate the implementation inside the test.
- **Test observable outcomes and required protections.** Avoid assertions about source spelling, private function structure, incidental call order, or call counts unless those properties are themselves requirements. Harmless refactoring should not require test rewrites.
- **Each additional case must catch a materially different failure.** Choose representative cases. Avoid exhaustive combinations that test the same failure repeatedly. Useful integration overlap is allowed.
- **Keep tests deterministic, repeatable, and isolated.** They must not depend on the author's working tree, credentials, or live services. Test that repeated operations are safe only where that is a required capability.
- **Use existing runners and fixtures.** Do not introduce a new test framework, proof platform, compulsory mutation suite, or abstraction for the cleanup. Remove tests belonging exclusively to removed capabilities. Keep cleanup within its agreed scope.
- **Report what the tests protect and what was actually checked.** State remaining evidence limits. Test counts, assertion counts, coverage percentages, and code volume are not delivery goals. A smaller or unchanged suite is a valid outcome.
