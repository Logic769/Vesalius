# The judge prompt

This is the exact prompt each judge received in round 2 of the [Vesalius benchmark](README.md), and the format of the
grades it sent back. It comes from the grading workflow we ran in Claude Code, which lives with our private benchmark
files. The prompt itself holds no private data, so here it is in full.

## How it was used

1. [`prep_grading.py`](prep_grading.py) writes one panel file per question and judge, and a list of all panels
   (`panels-<question ids>.json`). Each entry in that list has `task`, `judge`, `path`, `repository` and `count`.
2. A Claude Code workflow started one judge agent per panel, all in parallel. Each agent got the prompt below with the
   placeholders filled in from its entry, could read the repository, and had to reply in the format further down.
   Each agent was labelled `judge:${p.task}-${p.judge}`, which is the label
   [`extract_grades.py`](extract_grades.py) looks for when it collects the grades.
3. In round 2 that meant 20 panels: one per question, each holding the two answers to that question (one from each
   setup) and graded by one judge running `claude-opus-5-5`. Round 1 had three judges per answer (see
   [Round 1](#round-1) below).

### The placeholders

| Placeholder | Filled in with |
|---|---|
| `${p.path}` | The panel file to grade, for example `B3-judge1.json` in prep_grading.py's output folder. |
| `${p.repository}` | The folder of the frozen repository copy the answers are about: prep_grading.py's `--repos` folder joined with the question's `repo` from [`tasks.json`](tasks.json). |
| `${p.count}` | How many anonymous answers the panel holds. In round 2 that was two, one per setup. |
| `${p.task}`, `${p.judge}` | The question id and the judge number. They appear only in the agent's label, not in the prompt. |

## The prompt

```text
You are a judge on a blind grading panel. Read the panel file ${p.path} (JSON). It holds a developer's question about the repository at ${p.repository}, a verified answer key (required items with ids and weights, acceptable items, known incorrect claims, grading notes) and ${p.count} anonymous answers in random order. The repository is read-only for you: never create, edit or delete anything in it.

Grade EVERY answer independently, applying exactly the same standard to each:
1. matched: the ids of the key's required items that the answer actually contains, meaning it names that file, caller, symbol, cycle or fact, or an equivalent the grading notes accept. Vague hints do not count.
2. Claims: count the answer's concrete claims, meaning every file, symbol, caller, dependency, cycle, line reference or technical fact it asserts as part of its answer (each listed file or caller counts as one claim).
   - correct_claims: consistent with the key (required or acceptable items), or verified by you in the code.
   - incorrect_claims: contradicted by the key or the code, listed among the key's incorrect claims, or nonexistent (wrong file, wrong symbol, line numbers more than about 10 lines off, false relationships).
   For claims the key does not cover, check the code before deciding. Ignore hedges, advice and restatements of the question. List each wrong claim briefly with why.
3. holistic: 0 to 10, how useful and trustworthy the answer is for the developer, judged against the key. Do not reward length or style.

Return one grade per answer id, for all ${p.count} answers.
```

## What the judge sends back

One JSON object with a `grades` list that holds one grade per answer. Every grade has these six fields, all required:

| Field | Type | Meaning, as the schema describes it |
|---|---|---|
| `id` | string | the answer id, e.g. A017 |
| `matched` | list of strings | ids of the answer key required items this answer actually contains |
| `correct_claims` | integer | number of concrete claims that are correct |
| `incorrect_claims` | integer | number of concrete claims that are wrong |
| `incorrect` | list of strings | each wrong claim, briefly, with why |
| `holistic` | number | 0 to 10: how useful and trustworthy the answer is for the developer |

The same thing as the JSON Schema the workflow enforced:

```json
{
  "type": "object",
  "properties": {
    "grades": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": { "type": "string", "description": "the answer id, e.g. A017" },
          "matched": { "type": "array", "items": { "type": "string" }, "description": "ids of the answer key required items this answer actually contains" },
          "correct_claims": { "type": "integer", "description": "number of concrete claims that are correct" },
          "incorrect_claims": { "type": "integer", "description": "number of concrete claims that are wrong" },
          "incorrect": { "type": "array", "items": { "type": "string" }, "description": "each wrong claim, briefly, with why" },
          "holistic": { "type": "number", "description": "0 to 10: how useful and trustworthy the answer is for the developer" }
        },
        "required": ["id", "matched", "correct_claims", "incorrect_claims", "incorrect", "holistic"]
      }
    }
  },
  "required": ["grades"]
}
```

## What a panel file holds

- `task`: the question id.
- `repository`: the folder of the repository copy.
- `question`: the question from tasks.json, without the suffix the runs added.
- `answer_key`: the whole key: a summary, the required items (each with `id`, `item`, `kind`, `evidence` and
  `weight`), the acceptable items (`item`, `why`), the known incorrect claims (`claim`, `why`), the grading notes, and
  the list of `changes` its challenger made. [Answer keys](README.md#answer-keys) explains how they were built.
- `answers`: the anonymous answers in this judge's own random order, each with an `id` and the `answer` text.

Before the panel is written, prep_grading.py's `neutral()` replaces wording that would reveal the setup, in the
answers and in the key alike: "Vesalius", "code index", Vesalius 1's tool names and Vesalius 2's tool syntax all
become "the search". [Blind judging](README.md#blind-judging) has the details.

## How grades become scores

[`analyze.py`](analyze.py) reads only four of the six fields:

- `matched` gives recall: the weights of the matched required items over the weights of all required items. Ids that
  are not in the key are ignored.
- `correct_claims` and `incorrect_claims` give precision: correct claims over all claims.
- Quality is 100 times the F1 of recall and precision.
- `holistic` is reported as `usefulness` (times ten) in results.json and does not enter quality.

`id` ties each grade to its answer, and `incorrect` is there for people reading the grades.
[The score](README.md#the-score) has the rest.

## Round 1

Round 1 used the same prompt with three judges per answer. The only difference was its first sentence, which told each
judge its number: "You are judge ${p.judge} of three on a blind grading panel."

## Using another judge

Any model or agent that can read the repository and reply in the format above will do. Give it one panel at a time
with the placeholders filled in, then collect the grades into `grades.json` for analyze.py, as
[Run it on your own code](README.md#run-it-on-your-own-code) shows.
