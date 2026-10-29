# Contributing to StatsPro

[Player guide](README.md) · [Development reference](docs/DEVELOPMENT.md)

## Report a problem

Open a [GitHub issue](https://github.com/Antrakt92/StatsPro/issues) with your
StatsPro version, WoW build, client (Retail or Forever), class/spec and steps
to reproduce. Include a screenshot for display problems. For translations,
include the language and the label that needs changing.

## Set up and check

Use Git and PowerShell on Windows. Clone the repository so checks can read
tracked files and release history:

```powershell
git clone https://github.com/Antrakt92/StatsPro.git
cd StatsPro
.\scripts\check-lua.ps1 -EnforceToolLocks
```

The check downloads the locked tools into a temporary directory, verifies their
checksums and runs Lua 5.1 syntax checks, regressions, luacheck and LuaLS.
Tool versions and download sources are in
[`scripts/tool-version-locks.json`](scripts/tool-version-locks.json).

## Submit a change

- Keep a change and its regression coverage together. Describe the result and
  list the checks you ran in the pull request.
- Preserve Retail and Forever behavior. For game-facing changes, test login,
  combat and `/reload` in each affected client; include screenshots for UI work.
- Update affected translations. Preserve saved settings and third-party notices.
- Keep credentials, player data, local notes and build archives out of commits.

The [development reference](docs/DEVELOPMENT.md) covers the file layout,
architecture, smoke-contract updates and separate Retail/Forever releases.
Ordinary contributions do not need a release tag. See the
[changelog](CHANGELOG.md) for shipped changes.
