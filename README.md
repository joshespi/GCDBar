# GCDBar

A global cooldown bar for World of Warcraft (retail 12.0). It turns green when you're inside the spell queue window, and prints the % of each fight your GCD sat idle.

## Install

Install from CurseForge, or copy the `GCDBar` folder into `_retail_/Interface/AddOns/`.

## Commands

| Command | Effect |
| --- | --- |
| `/gcd unlock` | Show the bar so you can drag it |
| `/gcd lock` | Lock it in place |
| `/gcd size <w> <h>` | Set the size |
| `/gcd idle` | Toggle an empty bar in combat |
| `/gcd reset` | Default position and size |
| `/gcd stats` | Last fight's GCD idle % |

## Releasing

Add a `CHANGELOG.md` entry, then push a tag like `1.0.1`. GitHub Actions builds the zip with the [BigWigs packager](https://github.com/BigWigsMods/packager) and uploads it to CurseForge and GitHub Releases. Before that works, set the `CF_API_KEY` repo secret and add `## X-Curse-Project-ID` to the TOC.
