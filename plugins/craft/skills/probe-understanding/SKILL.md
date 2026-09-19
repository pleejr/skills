---
name: probe-understanding
description: This skill should be used when the operator wants their OWN grasp of a technical topic tested and improved by teaching it back in-session — a system just investigated, a document just read, a mechanism they have to explain to someone else tomorrow. Builds a sourced rubric first (session, vault, repo, live reads, web), then OFFERS a lesson per sub-area — mechanism, why, failure modes, boundaries, each anchored and sufficient to score full marks — before asking closed-book questions one at a time and scoring each sub-area 0-5 on those same four dimensions, citing the file, line or command behind every grade. A weak area gets a hint, then a full sourced explanation, then a fresh round — looping until every sub-area scores 5 or the operator stops. Triggers: "probe my understanding", "quiz me on this", "do I actually understand this", "make me explain it back", "check my mental model", "teach me this then test me", "teach me first, I don't know this yet", "I want to actually learn this, not just ship it". Distinct from `eli5` (a one-off plain-language explanation for a reader lacking the background — this teaches only to grade, and makes the operator produce the mechanism) and `scrutinize` (judges an artifact, never a person's grasp). NOT for documentation to hand to someone else, NOT for grading another person, and NOT for a factual lookup the operator wants answered.
version: 1.1.0
summary: Interactive teach-back drill — builds an evidence-sourced rubric, offers a lesson per sub-area that is by construction sufficient to score full marks, then asks closed-book questions one at a time and scores each sub-area 0-5 on mechanism, why, failure modes and boundaries with a citation behind every grade, looping hints then explanations into fresh rounds until the score is perfect or the operator stops.
---

# probe-understanding — make the operator teach it back, and grade it against evidence

Understanding is measured by what the operator can **predict and reconstruct unprompted**, not by what they recognize when shown. So the drill withholds the material, asks for the mechanism in their own words, and scores the answer against a rubric built from sources first.

Three things make this either useful or actively harmful, and none are negotiable:

- **Every grade cites evidence.** A score asserted from recall can mark a correct answer wrong, or bless a wrong one — and the operator will carry that away as settled. If a point cannot be sourced, it is not graded (§2).
- **The operator is offered the lessons before the drill, never given them by default.** The drill is worth most cold; it is worth nothing at all if the operator does not yet know the material and is just made to fail at it (§3).
- **Corrections cost points.** A 5 that survives being told the answer mid-round is a participation award; the loop only works if the score keeps running while a gap exists (§5).

## 1. Establish the topic and its sub-areas first

Invoked with a topic, take it. Invoked bare — the common case, mid-investigation — read the current session, then state in one turn:

- the topic as understood, in a phrase;
- the sub-areas it decomposes into, 2-6 of them, each a distinct mechanism rather than a subheading;
- that lessons will be offered per sub-area once the rubric is built, and that everything after the first question is closed-book.

Stop for confirmation or correction. A mis-scoped topic wastes a whole round, and the operator is the only one who knows which part they actually care about.

Sub-areas are the unit the score is kept in. Choose them so a gap in one does not imply a gap in another — "how the credential is fetched" and "what happens when it expires" are two sub-areas; "part one" and "part two" of a document are not.

## 2. Build the rubric before asking, from sources

For each sub-area, write down privately what a 5 looks like: the mechanism, why it exists, how it fails, and where it stops applying. Each of those points carries its source.

Source order, cheapest first:

1. **This session's own work** — files read, commands run, output already on screen. Legitimate and often best: the operator saw it, and whether it stuck is exactly the question.
2. **The vault** — `wiki-context` for prior decisions, lessons and repo pages.
3. **The repo or the live system** — read the code, run the read-only command. Prefer a value read back now over a recorded one.
4. **The web** — for standards, provider behaviour and documented defaults.

Then apply the rule that keeps the drill honest: **a rubric point with no source is dropped.** Not asked, not scored, not taught, not hinted at. Collect the drops and name them in the closing report as sub-areas that went uncovered, so a confident-looking perfect score never implies coverage it did not have.

The rubric is not shown as a rubric. It reaches the operator only as a lesson they chose (§3) or as remediation they earned (§6), and the source list is revealed in the closing report.

## 3. Offer to teach each sub-area before the drill starts

The rubric now exists, so the lessons can be given — and the operator, not the skill, decides whether they want them. Put the choice in one turn, listing the sub-areas by name:

- **Cold** — no lessons, straight to questions. Recommend this when the material was worked in this session or recently: the question in doubt is whether it stuck, and teaching it back first destroys the measurement.
- **Teach everything first** — a lesson on every sub-area, then the drill. Recommend this when the topic is new to the operator, or when they have said they must explain it to someone on a deadline.
- **Teach these** — lessons on the named sub-areas only, cold on the rest. The usual answer mid-investigation, where one or two sub-areas were never actually read.

Default to nothing. An unanswered offer is not consent to teach.

### What a lesson has to contain

The score is the **lowest** of four dimensions (§5), so a lesson that covers three of them guarantees a low score on the fourth and teaches the operator to fail. Every lesson therefore carries all four, in this order:

1. **Mechanism** — what happens, step by step, in order.
2. **Why** — what it exists for, and what goes wrong without it.
3. **Failure** — how it breaks, and what the breakage looks like from outside.
4. **Boundaries** — where it stops applying, and what it is commonly confused with.

Every point carries its anchor — `path/file.tf:88`, the command, the document — because the operator will want to go back to it, and because an unanchored sentence in a lesson is the same unverified assertion the grading rule exists to forbid.

**Nothing in a lesson that is not in the rubric.** Adjacent facts that will not be graded dilute the material the operator has to hold, and they are the shape ungraded lecture creeps in by. If a sub-area lost its points to the no-source rule, say that instead of teaching it — an unsourced lesson is worse than no lesson.

Say plainly what the lesson is: **the rubric, out loud.** Reproduce it unprompted and the sub-area scores 5 by construction — there is no hidden fifth thing being marked. That is the point of offering it, and knowing it changes what the operator listens for.

### Teaching does not cost points, and the drill starts after it

**A pre-drill lesson does not cap anything.** The cap at 4 in §5 is for corrections, hints and repeated prompting *inside a round* — if being taught capped the score, a taught sub-area could never reach 5 and the loop would never terminate. The lesson is the starting line, not a penalty.

The teaching phase is free in both directions: the operator may ask about a lesson, argue with it, or ask for it again, and every answer is sourced and costs nothing. **That stops at the first question.** From there the drill is closed-book, and asking for the material is remediation with the price §6 puts on it.

A lesson requested mid-drill is exactly that — remediation. Give it, and cap that sub-area's round at 4 like any full explanation.

### Do not then quiz the lesson back

An answer recited from a lesson given four turns ago measures the buffer, not the model. So, for a taught sub-area:

- **Ask transfer, not recall.** A new scenario, a changed input, a consequence the lesson did not spell out. Never a question whose answer is a phrase the lesson used.
- **Reverse the angle.** The lesson ran the mechanism forwards; ask it backwards — given this symptom, which step failed?
- **Interleave.** Put another sub-area's questions between a lesson and its own drill. Recall from a cold start is the thing being measured, and the spacing is free.

Mark taught sub-areas in the closing report (§8). A 5 earned after a lesson is a real 5 under this rubric, and it is still a different claim from a 5 earned cold — the report shows which one it is rather than arguing about it.

## 4. Ask one question at a time, closed book

One question per turn, and nothing else in the turn. The next question is chosen from the answer just given, which is the whole advantage of going one at a time.

- Prefer **prediction and reconstruction** over definition: "what happens to in-flight requests when this rotates?" discriminates; "what is a key policy?" invites a recital.
- Never offer options, never multiple-choice, never embed the answer in the question's phrasing. A question that can be answered by pattern-matching its own wording measures nothing.
- Do not quiz trivia — exact flag spellings, argument order, version numbers — unless the operator's stated goal is recall of exactly that. Grade the model, not the manual.
- An honest "I don't know" is scored as the gap it is (0 or 1 on that dimension) and moves straight to remediation. Do not award points for the honesty, and do not soften the score for it.
- Accept a partial answer as partial. Asking "anything else?" once is fine; asking three times until the operator stumbles into the answer is coaching, and it must cap the score the same way a correction does.

## 5. Score each sub-area on four dimensions

Every answer is scored on the four dimensions, each 0-5:

| Dimension | The question it answers |
|---|---|
| **mechanism** | What actually happens, step by step, in the right order. |
| **why** | Why it exists, and what would go wrong without it. |
| **failure** | How it breaks, and what the breakage looks like from outside. |
| **boundaries** | Where it stops applying, and what it is commonly confused with. |

The scale:

- **0** — no relevant claim, a guess, or "I don't know".
- **1** — names the vocabulary; no working mechanism behind it.
- **2** — partial mechanism carrying an error that would mislead a real decision.
- **3** — correct in outline, with gaps that needed correcting.
- **4** — correct and complete, but only after a correction, a hint, or repeated prompting.
- **5** — correct, complete and unprompted, with no correction applied.

**The sub-area's score is its lowest dimension**, because a confident mechanism with no idea how it fails is the exact shape of a dangerous mental model, and averaging hides it.

**Any correction applied to a dimension during a round caps that dimension at 4 for the round.** A 5 has to be earned cold, on a later round, after the explanation has had a chance to settle. This is what makes the loop terminate on understanding rather than on exposure. A lesson taken before the first question is not a correction (§3).

## 6. Remediate by escalation, not by telling

First miss on a sub-area: a **hint** — a narrowing question, a pointer to the mechanism one level down, the one fact that unblocks the rest. Retrieval effort is where the learning happens; skipping to the answer spends it.

Second miss on the same sub-area: the **full explanation** — the same four-part, anchored shape a lesson takes (§3) — and say plainly what the operator's answer got wrong versus what is true.

Then re-round: fresh questions on that sub-area only, phrased differently from the ones already asked, and not from the same angle as the explanation just given. Re-asking the explanation back verbatim tests short-term echo, not understanding.

If the operator is wrong about something the rubric cannot source, say so in those terms — "I think that is wrong, not verified, and here is what would settle it" — and drop the point rather than grading it.

## 7. The shape of a grading turn

Compact, so the drill keeps moving:

```
<sub-area> — mechanism 4 · why 5 · failure 2 · boundaries 3
```

Then only the corrections that change something, each with its anchor (`path/file.tf:88`, a command, a test name). Then the next question. No praise, no recap of what was right, no running commentary on the score.

Show the full table when the operator asks, when a sub-area first reaches 5, and in the closing report.

## 8. Exit, and what closes the session

The loop runs until **every sourced sub-area scores 5 on all four dimensions**, or the operator stops it. Either ending closes the same way:

1. the score table, per sub-area per dimension, marking which sub-areas were taught before the drill;
2. the sub-areas that were **never covered**, and why — no source, or the drill ended first;
3. the source list the rubric was built from.

Nothing else. In particular:

- **Write nothing.** No vault note, no project page, no `log.md` entry, no branch. This is study practice, and its footprint is the conversation. If the operator wants the gaps kept, they will say so — then it is `checkpoint`'s job, not this skill's.
- Do not offer a next drill, a study plan, or reading. The report ends the turn.

## 9. Failure modes to avoid

- **Grading from recall.** The single worst outcome is a confidently wrong correction, since the operator has explicitly asked to be taught and will believe it. Cite or drop.
- **Teaching unasked.** Delivering the lessons because the offer went unanswered, or because an answer was weak, converts a measurement into a lecture and there is no way back to the cold score.
- **A lesson that skips a dimension.** Three-quarters of the rubric taught, four-quarters graded, and the operator is set up to lose on the one they were never given.
- **Quizzing the lesson's own wording back.** The answer arrives from the buffer and scores 5 on nothing. Ask transfer, reverse the angle, interleave.
- **Score inflation.** Awarding 5 for an answer that needed three prompts empties the score of meaning and ends the loop early. The cap at 4 exists for this.
- **Leaking the answer.** In the question's wording, in the hint, in the choice of the next question. A hint narrows the search; it does not shorten it to zero.
- **Drifting into a lecture.** Once a full explanation is given, get back to asking. The operator learns by producing the mechanism, not by hearing it again.
- **Widening the topic.** Adjacent things worth knowing are not this drill. Finish the sub-areas that were agreed, and stop.
