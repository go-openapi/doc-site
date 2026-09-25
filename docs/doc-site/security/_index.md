---
title: Security advisories
description: Acknowledged security advisories on all go-openapi & go-swagger repositories at a glance
weight: 90
---

All security advisories at a glance — status (analysis, merged, released), reporter and fix releases, refreshed daily.

Advisories under analysis status remain to be acknowledged are not disclosed in full, just counted.
We try to keep as few as possible of those.

{{< advisories >}}

> [!Current posture regarding CVE]
>
> We are thoroughly reviewing security advisories that reporters kindly submit to our repos.
> We try to apply the necessary fixes and to release as promptly as possible.
>
> We publish valid advisories on GitHub's global database of security advisories: <https://github.com/advisories>.
>
> For the moment however, **we have suspended the next natural step, which is to request a CVE. Here is why**.
>
> Over the past couple of months, we have seen a very significant increase of reports produced in an entirely
> automated way. You might think this is great news.
>
> Sadly, all such reports follow a similar pattern:
>
> * they're all half-right, half-wrong or incomplete: finding the right half and filling the missing dots
>   is a ton of work that the reporter (or his/her) didn't care much about.
> * they are overly verbose, writing pages of analysis for a missing nil pointer check
> * the provided repro cases may not work, for non-obvious findings
> * they make a poor assessment of the context
> (what this lib is used for, what are the consequences of a change, how does the uncovered bug affects known
> dependent packages, etc);
> * they tend to exaggerate the threat - _anything_ is critical
> * there is (usually) no communication with reporters: fire and forget
>
> So we're done with that. Genuine findings are fixed, an properly attributed through the github advisories
> mechanism, we do like to credit people in our newsletters and the chase stops here.
>
> Reported advisories across GitHub as a whole are already overwhelming their reviewing capacity.
>
> We are willing to onboard genuine security analysts or people passionate about security.
> People we could engage with, challenge or learn from. That would change the stance on CVEs.
>
> The gamification of producing CVEs _en masse_ is not doing any good to anyone. So we're out of this game.
>
> What will happen now if we publish CVEs on every (legit) advisory, is that we create an incentive to receive even
> more slop, even more verbose half-correct, half-hallucinated reports, each the size of small book.
>
> We are willing to reconsider this position and we remain hopeful that things will eventually get back to normal.
> It takes only a few people to join our discord channel and signal their willingness to contribute
> to the security of the community's developments.
>
> We'd be happy to engage with people who get truly involved with our codebase, no passer-bys that send an
> errand agent.
>
> Yours truly,
>
> Fred
