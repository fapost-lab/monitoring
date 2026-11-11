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
