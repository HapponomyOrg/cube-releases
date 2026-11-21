<!--
The release workflow of The Cube (release.yml) publishes this file: it
copies the folder release/repo/ of the source repository to the default
branch of HapponomyOrg/cube-releases. Change the file there. A change made
only in cube-releases is lost at the next release.
-->

# Security policy

This policy covers The Cube: the programs `cube`, `cube-index`,
`cube-graph`, `cube-audit`, `cube-archive`, `cube-ghost` and `cube-ledger`,
the installers and the uninstallers, the signed channel
manifests, the starter kit, the architecture pack and the site at
https://happonomyorg.github.io/cube-releases.

## Report a vulnerability

Report a vulnerability only through GitHub's private vulnerability
reporting in this repository:

1. Open the [Security tab](https://github.com/HapponomyOrg/cube-releases/security)
   of this repository.
2. Click **Report a vulnerability**. This opens the
   [report form](https://github.com/HapponomyOrg/cube-releases/security/advisories/new).
3. Fill in the form and submit it.

Only you and the maintainers of this repository can see the report. You
need a GitHub account. There is no other way to report a vulnerability:
there is no e-mail address for reports.

Do not report a vulnerability in a public issue, in a pull request or in
any other public place.

Put this in the report:

- the output of `cube --version`;
- your system and its version (for example Ubuntu 24.04 on x86_64);
- the steps that show the problem;
- what the problem lets someone do.

Do not put private content from your knowledge base in the report.

## What happens next

The maintainers answer on a best-effort basis. There are no promised times
for an answer or for a fix.

1. GitHub tells the maintainers about your report.
2. A maintainer reads the report and answers in it. The conversation stays
   private.
3. When the maintainers confirm the problem, they fix it in a new release.
   A security fix is released as soon as it is ready. It does not wait for
   the next planned release
   ([When releases come](https://happonomyorg.github.io/cube-releases/alpha/releases/)).
4. When the maintainers find that the problem is not a vulnerability, they
   say why in the report and close it.

Keep the problem private until the fix is released.

## Versions that get fixes

A fix comes in a new release. A release that is out does not change: its
files on GitHub are immutable.

| Version | Gets fixes |
|---|---|
| The newest release | Yes |
| An older release | No. Update to the newest release. |

To update, run the installer again
([Install and verify](https://happonomyorg.github.io/cube-releases/start/install/)).

## Known limits

The [known limits](https://happonomyorg.github.io/cube-releases/alpha/known-limits/)
page lists the limits of the current release. A limit that is listed there
is known, and you do not need to report it.
