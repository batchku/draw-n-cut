# Kidwiz - Draw'n'Cut

## Kidwiz family — shared context

This app is one of five Kidwiz apps. Anything true of more than one of them
lives in `../kidwiz-site`, not here.

**Read `../kidwiz-site/KIDWIZ-FAMILY.md` before** changing App Store metadata,
privacy policy text, the support contact, sign-in configuration, or anything
touching the shared Firebase project. Those are settled positions held as
Springboard records; contradicting one is a change that needs Ali, not a
judgment call.

The points most likely to catch you out:

- Support and privacy URLs are `https://kidwiz.ai/<app>/support` and
  `https://kidwiz.ai/<app>/privacy`. Do not invent a new host or a new path.
- The apps ship **outside** the Kids Category, rated 4+. The Kids Category is
  closed to any app that sends children's photos or drawings to a third party.
- The Firebase project is `storai-b7b42`. Its id is permanent and must not be
  find-and-replaced. `authDomain` is `kidwiz.ai`.
- The published support address is `hi@kidwiz.ai`.
- The Apple team is `V9DBGV72NL` (IRL Labs LLC).

Learned something true of more than one Kidwiz app? Record it there, not here:

```bash
cd ../kidwiz-site
springboard record finding create --severity <info|warning|error> \
  --title "..." --summary "<one dense sentence>"
springboard record lint --prose
```
