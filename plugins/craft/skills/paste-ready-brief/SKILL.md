---
name: paste-ready-brief
description: This skill should be used when a finding, correction or status has to be handed to a colleague in a human thread — Slack, Jira, email, a pull-request comment — as a message the operator pastes, at exactly the length asked for: a one-sentence tl;dr, a 3–5 paragraph brief, or a full write-up. Produces one fenced block, unwrapped single-line paragraphs, dates and identifiers exact, inferences marked as inferences with the caveat that bounds them, secret values withheld, one ask at the end — and it is handed over, not sent. Triggers: "write me a tl;dr", "tl;dr for the team", "quick write-up for Slack", "write this up so I can paste it", "correct what they said", "what should I tell them", "put this in a paste-ready form", "summarise this for the channel". Distinct from a tool that posts or drafts inside the chat app itself (choosing the identity and the thread) — this one hands the operator text to paste, anywhere. Distinct from `eli5` (which explains a concept to someone lacking the background) — this reports a finding to a peer who has it. Distinct from a durable wiki page with its own conventions — this is a one-off message. NOT for the operator-facing report of your own turn, and NOT for sending — the message goes out only when the operator explicitly asks.
version: 1.1.0
summary: Author a paste-ready message for a human thread at the length asked for — one-line tl;dr, short brief, or long form — fenced, unwrapped, with inferences marked and secrets withheld.
---

# paste-ready-brief

A finding that lives only in this session is worth nothing to the colleague who has to act
on it. Getting it to them is a different writing job from reporting it to the operator, and
the failure is not length — it is that a message written in the operator's register arrives
in a human thread as a wall of hedged narration nobody reads to the end of.

Three things make it land: the right length, a shape that survives being pasted, and a
claim the reader can trust because its limits are stated.

## 1. Pick the length from what was asked, and honour it literally

These are three different documents, not one truncated three ways.

| Ask | Length | What it carries |
|---|---|---|
| "tl;dr" | **one line, 15–20 words** | only the conclusion that changes the reader's next action |
| "quick write-up", "brief" | 3–5 short paragraphs | conclusion, the evidence for it, one ask |
| "write it up", a correction | as long as the evidence needs | mechanism, quoted output, caveats, consequences |

**A tl;dr is one sentence.** Not a short section, not a lead paragraph with bullets under
it — one line somebody reads in the notification preview and already knows what changed.
Getting this wrong is the commonest failure here, and it is invisible from the inside: a
five-paragraph message with the word "tl;dr" at the top reads, to its author, like a
summary. It is not; it is the brief, mislabelled. If a draft called a tl;dr has more than
one sentence in it, the ask was not answered.

Write the tl;dr as the thing that changes the reader's plan, not the thing you discovered:

- Good: *"The reports don't use that credential; Airflow's failure email does, and it's been broken since March."*
- Bad: *"I traced the send path through the DAG code and found that email is sent via the SES API rather than SMTP."*

The second is true and describes your afternoon. The first tells them their plan for next
week is wrong.

Offer the next length up in one clause outside the fence — never by padding the tl;dr.

## 2. Shape it to survive the paste

- **Put the whole message inside one fenced block, and nothing else in it.** The operator
  copies the fence contents wholesale; commentary of yours sitting inside it gets pasted
  into someone else's thread.
- **Frame the fence with horizontal rules.** A blank line, `---`, a blank line above the
  fence, and the same below it. The terminal draws no border around a fence, so the rules
  mark where the paste starts and ends. They sit outside the fence and are never copied.
  Keep the blank line above each `---`: directly under a text line it renders as a heading.
- **No hard wraps.** Every paragraph is a single unwrapped line. Slack, Jira, email and
  pull-request comments all reflow to the reader's window, so text pre-wrapped at 76
  columns arrives ragged. This is the correction operators actually make.
- **Blank line between paragraphs**, since that is the only paragraph break that survives.
- **Bullets sparingly, one line each**, and only where the content is genuinely a list —
  two options, two consequences. A bulleted message reads as a status report.
- **Never a `<placeholder>` inside a URL, a command, or an identifier.** A pasted link with
  an angle-bracket hole in it is a broken link in a channel with an audience. If a value is
  genuinely unknown, leave the sentence out and say so outside the fence.
- **Quote real output verbatim** on its own line — an error string is the most persuasive
  thing in the message and paraphrasing it destroys that.

## 3. Make the claim trustworthy inside the message

The operator already knows which parts you measured. The colleague does not, and they are
going to act. So the marking has to be in the message, not only in your report to the
operator.

- **Separate measured from inferred, in the prose.** "The scheduler log carries this
  repeatedly" is a measurement. "That fits the Airflow 3 upgrade" is a fit, and saying
  "fits" rather than "is because of" is the whole difference.
- **Carry the caveat that bounds the claim.** If the evidence cannot distinguish two
  explanations, say which one it cannot rule out: *"that write happens before the send, so
  all I can say is the task stopped reaching that line, not why."* A colleague who
  discovers the limit themselves discounts everything else in the message.
- **Give dates and identifiers, not "recently" and "the thing".** `2026-03-05`, the exact
  log group, the exact function. These are what they will search for.
- **Withhold secret values and name the location instead.** A key id, a variable name, a
  file path, a resource arn — yes. The password, the token, the private key — never, in any
  length, however internal the channel feels. Point at the ticket or the vault page that
  holds what a reader with the right access needs.

## 4. Correcting somebody's premise

The highest-value message of this kind is usually a correction, and it is the easiest one
to get socially wrong. The rule is to correct the premise and leave the person out of it.

- **Lead with the mechanism, not with the disagreement.** "The reports never touch that
  credential — here is the send path" beats "that isn't right".
- **Never quote their belief back at them.** They said it in good faith with less evidence;
  restating it only to knock it down reads as scoring a point.
- **Say what it changes for them, concretely.** A correction that does not alter anybody's
  next action did not need sending.
- **Keep what they were right about.** If they said the thing matters and it does, say so —
  the correction is to the mechanism, usually not to the priority.
- **Separate the unrelated finding.** If something else turned up, put it in its own final
  paragraph and label it as unrelated, so it cannot be read as part of the argument.

## 5. Hand it over; do not send it

The message is a draft for the operator to paste. Sending it is an outward-facing act
against a real audience, so it needs an explicit instruction — "send it", not "write it".

- Present the fence, and outside it put at most one line: what is still owed, or the choice
  the operator has to make.
- If the operator does ask for it to be sent, the fence you just showed is the preview, and
  it goes as-is rather than being rewritten on the way out.
- Re-read the fence once as the recipient before handing it over: unknown acronyms, an
  identifier only this session has seen, a sentence that only parses if you watched the
  investigation. Those are the lines to cut.

## 6. Checklist

- [ ] Length matches the ask — a tl;dr is **one sentence, 15–20 words**.
- [ ] The lead states what changes the reader's next action, not what you did.
- [ ] Whole message in one fence; nothing of yours inside it; a `---` rule above and below it.
- [ ] Paragraphs unwrapped, single lines, blank line between them.
- [ ] Inferences read as inferences; the bounding caveat is present.
- [ ] Dates, identifiers and quoted output exact; no secret values.
- [ ] No `<placeholder>` inside any URL, command or identifier.
- [ ] One ask, at the end of the message.
- [ ] Handed over, not sent.
