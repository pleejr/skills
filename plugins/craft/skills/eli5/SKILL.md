---
name: eli5
description: This skill should be used when explaining a technical concept, system, error, or piece of code in plain language to someone who lacks the background — a non-engineer, or an expert from another domain — using an analogy that carries the explanation rather than decorating it. Produces a short answer: the mechanism in one sentence, an analogy mapped part-by-part onto it, where that analogy breaks down, and the real vocabulary to take away. Guards against decorative analogies, jargon-swapping, and unflagged lies-to-children. Triggers: "ELI5", "explain like I'm five", "in plain English", "explain this simply", "layman's terms", "no jargon", "give me an analogy for", "how would you explain this to a non-engineer", "dumb this down", "I don't have the background for this", "what does this actually mean". Distinct from `expand-acronyms` (a standing output mode spelling out abbreviations in every reply — this is a one-off explanation of a concept), `paste-ready-brief` (a thread message for a competent peer in another specialism — that keeps the vocabulary and drops the narration; this replaces the vocabulary with an analogy) and `scrutinize` (evaluates an artifact; this explains rather than judges). NOT for authoring user-facing docs, tutorials, or a README, and NOT for shortening a technical answer for an expert — use it when the reader lacks the background, not the time.
version: 1.0.1
summary: Plain-language explanation with a load-bearing analogy — mechanism in one sentence, analogy mapped part-by-part, where it breaks down, and the real vocabulary — with guards against decorative analogies, jargon-swapping, and unflagged simplifications.
---

# eli5 — explain it simply without making it wrong

The hard part of a simplified explanation is not making it simple; it is staying **correct** while doing so. A fluent analogy that installs a wrong mental model is worse than no analogy — the reader now has confident false intuition and no reason to question it. Optimize for what the reader can correctly predict afterwards, not for how smooth it sounded.

"Five" describes the reader's **prior knowledge**, not their intelligence. Never write down to them.

## Method

**1. Pin the mechanism first.** Before reaching for any analogy, state what actually happens in one technically correct sentence (internally, if not in the output). An analogy cannot be mapped onto something not yet pinned down — skipping this is how decorative analogies get in.

**2. Pick the analogy for structure, not vibe.** The right source is something in the reader's ordinary experience whose *causal relationships* match the target's: same actors, same constraints, same failure modes. Surface resemblance ("it's like a highway") is not structural match.

**3. Map it explicitly.** Name which part of the analogy corresponds to which part of the real thing. This is the load-bearing test: if a piece of the mechanism has no counterpart, the analogy is too small — extend or replace it. If the analogy can be deleted with nothing lost, it was decoration.

**4. State where it breaks.** Every analogy diverges somewhere. Say where, before the reader walks into it. One sentence: "this stops holding once X, because…" Naming the boundary is what makes the analogy safe to use.

**5. Land back on the real terms.** Close with the actual vocabulary, briefly defined. The reader should be able to search, ask a follow-up, or read the docs afterwards — an explanation that leaves them fluent only in the analogy has stranded them.

## Failure modes to avoid

- **Jargon-swapping.** Replacing a term with its longer definition is not simplification: "idempotent" → "safe to apply repeatedly without changing the outcome after the first time" is progress; "idempotent" → "having the property of idempotency" is not. Test: could a sharp twelve-year-old with no domain background follow the sentence?
- **Decorative analogy.** Introduced, then never used again. If the mechanism is explained entirely in the paragraph *after* the analogy, cut the analogy.
- **Analogies that smuggle wrong intuitions.** The most common damage. Ask what a reader would *wrongly predict* from the analogy; if it is something they'd plausibly act on, pick a different one.
- **Unflagged lies-to-children.** Some simplifications are knowingly false but pedagogically necessary (a scaffold to be discarded later). That is legitimate — flag it inline rather than pretending: "roughly; it's actually more like…". The reader should know which parts will need revising.
- **Length.** Compression is the deliverable. Default to ~150 words; past ~300 the ELI5 has failed at its own job. Split into two passes rather than sprawling.
- **Answering an easier adjacent question.** Simplify the explanation, never the question. If the honest answer is "this is genuinely irreducible," say that and explain it plainly.

## When no good analogy exists

Some things have no honest counterpart in everyday experience. Forcing one is how wrong models get installed. Say so and explain plainly in short, concrete, jargon-free sentences — a clear literal explanation beats a strained figurative one. Partial analogies are fine when scoped: "only the *timing* works like a queue at a deli counter; nothing else does."

## Shape of the output

Prose, not headers — this is short enough not to need scaffolding. In order: the one-sentence mechanism, the analogy with its mapping, where it breaks, the real terms. Offer the technical version as a one-line closing question rather than appending it by default; the reader asked for the simple one.
