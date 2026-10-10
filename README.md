# aur-taw (The Arch Way)

A small, opt-in AUR helper written in Bash. Track selected packages, import existing installations, review recipe changes, and build on disk in `~/.cache/aur-taw`.

## Installation

On Arch Linux:

```bash
sudo pacman -S --needed base-devel git curl jq less util-linux coreutils bubblewrap libarchive
git clone https://aur.archlinux.org/aur-taw.git
cd aur-taw
makepkg -si
```

To install this development checkout:

```bash
sudo make install
```

Isolated builds require bubblewrap with `--ro-overlay` support (version 0.13 or newer), enabled unprivileged user namespaces and overlayfs. aur-taw refuses to build if isolation is unavailable; it never falls back to an unprotected build. Install missing official build dependencies explicitly before retrying.

The default version is `1.3.0-dev`. Development builds exclude aur-taw itself from AUR checks and upgrades. Other tracked packages are checked normally. `sudo make uninstall` removes a development installation. Use the same `PREFIX` for installation and removal if you override it.

Bash completion is installed automatically; open a new shell or run:

```bash
source /usr/share/bash-completion/completions/aur-taw
```

## Commands

### Add and edit

```bash
aur-taw add music https://aur.archlinux.org/spotify.git
aur-taw edit music --name player
aur-taw edit player --url https://aur.archlinux.org/spotify-launcher.git
```

`add` obtains the latest available AUR version immediately. If metadata cannot be fetched, it explicitly saves `Unknown`; the installed version is never used as the remote version. Run `check` once connectivity returns. An existing alias must be changed with `edit`.

`edit` works on imported packages as well. Renaming preserves the exact package name, cached version, and origin. Changing the source or package identity resets the origin to `added`. The self-update entry cannot be redirected or renamed.

For a split repository, specify the exact output package when necessary:

```bash
aur-taw add my-component https://aur.archlinux.org/PACKAGEBASE.git --package PACKAGE
aur-taw edit my-component --package OTHER-PACKAGE
```

The repository base and installed package name are separate identities. Multiple outputs of one repository can be tracked individually. Package variants such as `foo`, `foo-git`, and `foo-bin` are distinct; aur-taw never strips suffixes to guess whether a package is installed.

### Discover and import

```bash
aur-taw discover
aur-taw import
aur-taw import --all
aur-taw import spotify
```

`discover` queries installed foreign packages and verifies which are currently on AUR. It reports untracked packages, imported packages, packages installed through aur-taw, entries only added to the registry, and legacy entries whose origin is unknown. Local packages and packages removed from AUR are identified separately. An unavailable AUR service is reported as unverified, never as proof that a package is absent.

Import reports installed and available versions, the package base, per-package results, and summary counts. It uses AUR's `PackageBase` for split repository URLs, preserves existing aliases, and resolves alias collisions without overwriting another entry. It never builds a package or establishes a trusted security baseline.

Packages already imported or installed through aur-taw are excluded before querying AUR: they do not appear as import candidates or generate repeated package details. Scans also exclude entries already present in the legacy registry, whose original install/import provenance was not recorded; an explicit `import <package>` can still record that provenance. If everything is already registered, import reports that there are no new packages to import, without network requests. Entries only created with `add` remain eligible.

Provenance records operations performed by this version of aur-taw. It cannot reconstruct which helper installed a legacy package, or detect later reinstalls performed by another tool.

### Install, upgrade, and downgrade

```bash
aur-taw install player
aur-taw check
aur-taw install player --upgrade
aur-taw install --all
aur-taw install --all --upgrade
aur-taw log player
aur-taw install player@a1b2c3d
```

If the requested package is already installed but has not been imported, aur-taw blocks the installation and offers to import it. That invocation never continues to install, even if import is accepted. This also applies to an untracked installed package passed by its actual name. Imported or previously installed packages require `--upgrade` or an explicit historical commit for a rebuild.

Upgrade decisions use the last cached AUR version; run `check` first. Ordinary checks compare published AUR versions, so a new upstream commit without an AUR version change is not detected for VCS packages. Historical recipes may still download current upstream code or reference binaries that are no longer available.

Every build requires a security review. `--all` confirms the batch, then requires approval for each recipe. makepkg runs in an isolated environment; aur-taw checks the name and package base of every resulting archive against the approved `.SRCINFO`. The standard `pkgbase-debug` output is also allowed. An output registered under another repository is rejected, including imported packages. Archives are hashed and checked again before installation. Missing AUR build dependencies must be added/imported and selected explicitly; aur-taw does not recursively execute unreviewed recipes.

When upgrading multiple entries, including `install --all --upgrade`, aur-taw orders the selected repositories with dependencies first and displays that order before building. It uses the installed runtime dependency graph, including virtual providers and transitive relationships through other installed packages. Split outputs from the same repository are built once. Previously prepared packages are made available only inside the next build’s isolated environment. All prepared archives are then installed in **one pacman transaction**, allowing coordinated updates such as `app 1 → 2` together with its exact dependency `lib=1 → lib=2`. If any review/build fails or is blocked, the entire batch stops before host installation. A dependency cycle between repositories requiring upgrades also stops the batch before building. pacman still validates the final dependency set; this does not provide rollback after a machine failure or a failing installation hook.

This order describes the currently installed runtime relationships. Newly introduced dependencies in an upcoming recipe, and build/check dependencies, are not inferred by this scheduler. Pacman and makepkg still enforce package requirements during the build/install process; the usual security review remains required.

### Versions and background checks

```bash
aur-taw list
aur-taw check
aur-taw check --installed
aur-taw autocheck enable
aur-taw autocheck status
aur-taw autocheck run
aur-taw autocheck disable
```

`list` displays cached remote versions and current installed versions without network requests. During `check`, HTTP errors, invalid JSON, or unavailable packages preserve previously known versions and return an error. Manual checks and autocheck share one lock covering the request and merge, so a delayed background response cannot overwrite a newer manual result. Non-AUR repository URLs have no AUR version source and are skipped by `check`.

If installed and available versions differ but `vercmp` considers the installed version newer or equivalent, `check` and `install --upgrade` display `VERSION MISMATCH`, both versions, and the comparison result. This can happen with different version schemes or stale VCS metadata: for example, an installed `.r1154.ef2c16e-1` sorts above AUR's `0.1.0.r0.0-9`. The warning explains why no automatic update is selected; it does not establish that the installed upstream code is current. `check --quiet` suppresses this output; automatic checks retain it in their log. `list` only shows the version table, without mismatch warnings.

`autocheck enable` installs a **systemd user timer** that checks tracked, installed packages every six hours, with a randomized delay and a check after session startup. It runs while your user systemd manager is available. It only refreshes version metadata: no builds, installs, or automatic security approvals. Enable it explicitly after installing aur-taw; a timer created from a checkout depends on that checkout remaining at the same path.

Units are written beneath `${XDG_CONFIG_HOME:-~/.config}/systemd/user/`. The latest automatic result and log are under `${XDG_CACHE_HOME:-~/.cache}/aur-taw/`; `autocheck status` shows their locations. `disable` stops the timer and an in-progress check. Disable the timer before uninstalling aur-taw.

### Dependencies

```bash
aur-taw deps
aur-taw deps player
aur-taw deps player --tree
aur-taw deps --tree
aur-taw deps --all
aur-taw deps --all --tree
```

`deps` reads actual runtime dependencies from pacman's local database, including versioned dependencies and virtual providers. The default view is limited to installed AUR packages tracked in aur-taw and their relationships. The compact table shows each dependency once alongside the AUR packages that require it. Use `discover` and `import` to include other installed AUR packages in this view.

Tables and trees show registered aliases, including the `REQUIRED BY` column; packages without an alias use their real name. Trees include only brief cycle/repeated-node markers where necessary. Missing packages, build/check declarations and optional dependencies are excluded. `--all` explicitly broadens the view to official installed packages; the flat `--all` listing shows aliases/names and versions of packages marked as dependencies by pacman. The snapshot refreshes on imports, installs, removals and `deps`; it does not change installation reasons or install/remove anything.

### Other commands

```bash
aur-taw search spotify
aur-taw view player
aur-taw log player
aur-taw remove player
aur-taw uninstall player
aur-taw --help
aur-taw --version
```

`remove` only forgets an uninstalled package. `uninstall` invokes `pacman -Rns` and can then remove its registry entry. Uninstalling aur-taw keeps your registry/cache and other AUR packages; remove the configuration manually if you no longer need it.

## Recipe security review

Before executing any `makepkg` command, aur-taw reads Git objects as data:

- On the first build, it displays **all tracked files**, including `PKGBUILD`, `.SRCINFO`, patches and `.install` hooks.
- Later builds show the diff against the last successfully installed, approved commit. Missing history causes a full review. Imports never count as approval.
- Static checks flag download-and-execute patterns, encoded scripts, inline interpreters, network operations, persistence/credential access, and known campaign package names.
- AUR maintainer changes and orphaned packages are highlighted when ownership metadata is available.
- Symlinks, submodules, binary/control-byte payloads and excessively large recipes are blocked. Git hooks, external diff programs and text conversions are disabled in the review path. The actual checked-out file bytes must also match the reviewed Git objects.
- The user must type `APPROVE` in an interactive terminal before each build. Batch mode cannot bypass this. A failed build or rejected review does not advance the baseline.

Builds use bubblewrap with a private HOME, temporary directories, a cleared environment and selected system files. Host credentials, the registry, agent sockets and the host temporary directory are not exposed. System tools and staged dependency files are read-only; package code cannot use host sudo. Source download, signature verification and `prepare()` run with network access inside this environment (`makepkg --nobuild`); compilation, tests and packaging then run without network access (`--noextract --holdver`). Recipes that download extra files during compilation must fetch them in their source or preparation phase instead. Missing official dependencies must be installed explicitly. Only public signing keys matching fingerprints declared in the approved `.SRCINFO` are exported into the private build keyring; secret keys and the rest of the host keyring are never copied. A missing key stops the build and reports its fingerprint for explicit import. Source preparation shares the host network, including localhost/LAN: it is not a network firewall. Staged packages overlay the installed system tools; this is not a clean chroot, and files removed by a dependency update can remain visible in the build environment.

This is a **review aid, not a malware guarantee**. Legitimate recipes can trigger warnings, and malicious code can evade patterns. Downloaded sources, mutable upstream code, build tools, and dependency archives are outside the recipe diff. Read the changes and verify upstream sources before approval. The installed package and its installation hooks still become trusted system code: isolation protects the build phase, not execution after installation. Do not configure passwordless, unrestricted pacman access to make builds unattended.

The [Arch AUR guidance](https://wiki.archlinux.org/title/Arch_User_Repository) recommends inspecting build files. The [reported gnome-randr-rust takeover](https://lists.archlinux.org/archives/list/aur-general%40lists.archlinux.org/thread/L2JXQNYBGWOQQQXDEPEAICBHKFEFANUC/) illustrates why the review includes install hooks and ownership changes.

## Registry integrity and migration

Configuration uses `${XDG_CONFIG_HOME:-~/.config}/aur-taw/`; cache uses `${XDG_CACHE_HOME:-~/.cache}/aur-taw/`.

`repos.txt` now has five whitespace-separated fields:

```text
alias repository-url latest-aur-version exact-package-name origin
```

Origins are `added`, `imported`, `installed`, `bootstrap`, or `tracked` for legacy entries. Old two/three-column files migrate automatically, with a backup at `repos.pre-v2.bak`. Legacy version caches are reset to `Unknown` because older versions mixed installed and remote values; run `check` after migration. Incompatible old aliases are migrated to collision-free `legacy-...` names, with the mapping printed and the exact original registry backed up. Existing valid aliases are retained. Legacy source-to-package mappings are retained; use `edit --package` to correct old split-package guesses.

Registry writers use a stable `flock` lock and validate the entire replacement before publishing. Temporary files live in the destination directory, are private to the user, are synced before an atomic rename, and the filesystem is synced afterwards. Failed writes leave the previous registry intact. Version checks merge only matching source/package identities under the lock, preserving concurrent additions, edits and removals. Never edit the registry manually while aur-taw is running.

## Development and release

Check Bash syntax from the source directory:

```bash
for script in aur-taw aur-taw-completion.bash lib/*.bash; do
    bash -n "$script" || break
done
git diff --check
```

The Makefile also defines `make test` and `make test-docker` (using the `aur-dev` image by default). Both require `tests/run.bash` and its regression fixtures. **The `tests/` directory is absent from this source snapshot**, so these targets cannot currently run. Restore the regression suite before using them to validate a release; syntax checks alone do not verify behavior.

See [Publishing an update to AUR](docs/RELEASING.md) for the source release, PKGBUILD update, checksums and `.SRCINFO` workflow.

## License

[MIT](LICENSE).
