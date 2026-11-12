## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `make check` passes (unit tests, release build of the app, command line smoke test)
- [ ] New behaviour has a test where it can have one; anything that needs real headphones was tried by hand (see CONTRIBUTING.md)
- [ ] If the panel changed: `make preview` run and the screenshots in `docs/images` updated
- [ ] No personal data in tests, fixtures or docs (names, device addresses, serial numbers, probe logs with MAC addresses)
- [ ] README and CHANGELOG updated if behaviour changed
- [ ] Nothing new writes to the headphones without being asked to, or talks to the network
