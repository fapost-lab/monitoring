# The review draft, version 1

The one file a review is built from. `jig pr draft <n> --from <file>` checks it against this page
and the fetch, keeps it with its CRs dropped, and prints it. `jig pr comments check <n>` builds from
it the review as it will be posted — what the person approves, byte for byte — and
`jig pr comments post` posts that and nothing else.

```
jig-pr-draft: 1
url: <the URL jig pr fetch printed: https://github.com/<owner>/<repo>/pull/<n>, or https://<host>/<group>/<project>/-/merge_requests/<n>>
head: <the reviewed head, 40 hex>
login: <the account it will be posted as>
language: <the comments' language, e.g. en>

=== summary
<the review's body, markdown>
=== levels
P0 <word> — <what it asks of the author>
P1 <word> — <…>
P2 <word> — <…>
P3 <word> — <…>
=== comment P1 R42 src/app.go
<a finding's title on the first line>
<the rest of it>
=== comment R42 src/app.go
<a comment on line 42 of the new side>
=== comment L17-20 src/old.go
<a comment on lines 17 to 20 of the old side: lines the PR deleted or changed>
=== personal R10 src/app.go
<a finding that rests only on the person's own rules: shown, never posted>
=== reply 1 fixed
<a follow-up's answer in thread 1 of jig pr followup: the verdict on its first line>
```

- **Header**: these four keys after the first line, each once, then a blank line. `url`
  and `head` must be what `jig pr fetch` recorded; `login` one of the accounts it found. A
  follow-up adds a fifth, `follows: <sha>`: the head `jig pr followup` says was reviewed last.
- **Blocks** start with a line `=== <kind> …`. `summary` comes first, once, and takes nothing
  after it. `comment` and `personal` take a position and a path. `reply` (a follow-up's only)
  takes a thread number of `jig pr followup` and a verdict, `fixed` or `open`: every thread it
  lists gets exactly one.
- **Levels** are optional and all or nothing. A `=== levels` block, right after the summary, names
  the four severities of the review method (the fetch's `method:` file) in order, one a line:
  `P<n> <word>[ — <meaning>]`, in the review's language (`P0 Blocker — before the merge`). With it,
  every `comment` and `personal` names its level before the position (`=== comment P2 R42 …`);
  without it, none does. The first line of such a comment is its title: one line of plain text, not
  empty and not the start of a block (a fence, a heading, a quote, a rule, a table, indented code).
- **What levels add** is jig's, at `jig pr comments check`: each level a colour (P0 🔴, P1 🟠,
  P2 🟡, P3 🟢); the comments numbered by level, P0 first, then in the draft's order, each body
  starting `🟢 **3.** `; and after the summary a legend of the four lines and, per level with
  findings, its word and the numbered titles. A comment moved into the summary keeps its number;
  `personal` blocks are never numbered. The words are the draft's — jig writes no prose of its own.
- **Position**: `R<line>` on the new side (the head), `L<line>` on the old side (the merge base),
  `-<end>` for a range on the same side, ending after it starts.
- **Path**: the rest of the line, relative to the repository, without `.` or `..`; a file of the
  head for `R`, of the merge base for `L`.
- **Bodies** are markdown and may not be empty. No body line may start with `=== `.
- **A follow-up's comments** are `R` comments on lines the author added since `follows`, unless
  `jig pr followup` said the reviewed head is unreachable.
- Whether a line lies inside the pull request's diff is decided by `jig pr comments check`, against
  the forge's own diff (GitHub's or GitLab's): a comment outside it is moved into the summary, never
  dropped.
