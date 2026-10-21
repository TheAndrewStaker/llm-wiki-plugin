---
type: signal
title: <storyline name, not a document ID>
description: <one sentence: what is changing and for whom>
kind: <one of the configured kinds, e.g. rule | statute | litigation | recurring-report | market>
stage: <a stage allowed for that kind>
relevance: <direct | adjacent | background>
next_expected: <YYYY-MM-DD, the next dated event, or omit when unknown>
next_expected_what: "<what happens on that date; mark (est.) when estimated>"
recheck: <YYYY-MM-DD, required when next_expected is unknown>
first_seen: <YYYY-MM-DD>
last_event: <YYYY-MM-DD of the newest log entry's event>
aliases: [<every identifier a later source may use: document IDs for each stage, docket or RIN, bill number, statute section, popular name>]
touchpoints: [<relative links to the wiki pages this affects>]
synthesized_from: [<staged sources or notes pages, newest last>]
timestamp: <YYYY-MM-DD, last meaningful change to this page>
---

# <title>

**What it is.** Two or three sentences: who is acting, on what, and the current stage.

## What it means for us

Each claim marked with the wiki's confidence vocabulary and linked to the page that owns the fact
(an entity or concept page with its own survey date), not to code paths that nothing watches.
Restate this section whenever the stage moves; a final rule can flip a proposed rule's impact.

## Log

Newest first. One entry per source. A primary document (rule text, filing, report) gets its own
notes page linked here; a secondary article is a line here with its staged source.

- **YYYY-MM-DD** · <stage or event> · <what changed, one or two lines> · [source](<path>)
