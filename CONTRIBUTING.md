# Changing review-tools

Every change to a skill's rules is a **rev**. A rev is one commit that holds the rule, its entry
on the reference page, and its corpus rows in both copies. The commit gate
(`hooks/require_code_review.sh`) blocks a commit or push in this repo that leaves any of them
out, including one made with `cd ~/repo/review-tools && git commit` or `git -C` from another
checkout. Run the same check by hand first:

```sh
bash hooks/check_reference.sh . <rev>
```

It prints one line per problem and exits 1, or prints nothing and exits 0.

## 1. Pick the rev number

Take the next number after the page subtitle (`Generated DATE, rev N` in
`reference/code-review-reference.html`) and after `git log --oneline -5`. Pull first: several
machines and sessions add revs, and two commits with the same rev must be renumbered by hand.

## 2. The rule: `skills/<skill>/SKILL.md`

Put each bullet under the angle the corpus row will name, not at the end of the file. Name the
miss that motivated it (PR or branch, round, date).

## 3. The page: `reference/code-review-reference.html`

All four parts, every rev:

1. **Subtitle:** `Generated YYYY-MM-DD, rev N`.
2. **Changelog:** a `<div class="changelog-body"><strong>rev N</strong> (DATE) &mdash; ...</div>`
   inserted *before* the previous rev's entry: what was missed, why, and the new rules.
3. **Angle card:** for each new bullet, a
   `<div class="check-item"><span class="check-bullet">&bull;</span>... (rev N)</div>`
   appended inside that angle's `angle-checks` div. It must end with `(rev N)`.
4. **Angle panel:** for each new bullet, an entry in that angle's `checks:` array in `angleData`,
   `'<strong>Title (rev N).</strong> Body.'`. Single-quoted JS strings: write `'` as `&rsquo;`
   and `"` as `&ldquo;`/`&rdquo;` or `&quot;`; the previous entry needs a trailing comma.

A rule about the process rather than an angle (Phase R, logging, the gate) gets an `<li>` in
the Phase R panel ending `(rev N)` in place of 3 and 4.

A new required artifact also gets a `recipe-step` div next to the related ones (for example
"Mutation log (rev 94)", "Model ledger (rev 97)").

## 4. The corpus: both copies, same rows

`reference/code-review-misses.md`: the current table has **four columns**.

```text
| Class | Angle | What was missed | Detector / check |
```

- **Class:** a short name for the kind of miss.
- **Angle:** the angle letter (`J`), `Phase R` or `Hard rule N`.
- **What was missed:** the source (PR, round, date, confirmed count), the shapes it missed,
  `Existing rule: ...` and `Why it failed: ...`.
- **Detector / check:** the new enforcement: `New: the Angle J bullet "..."`, a detector, a
  matrix row, or `None new: disclosed limits.` Never put `New:` text in the third column.

Escape a pipe inside a cell, code included, as `\|` (`x \|\| y`), or it splits the cell.

`reference/code-review-misses-data.js`: one entry in `MISS_ROWS` per Markdown row, appended
before the closing `];`, as a JSON string (`json.dumps(..., ensure_ascii=False)`) of:

```html
<tr>
      <td><span class="class-label">CLASS</span></td>
      <td><span class="angle-ref">ANGLE</span></td>
      <td>WHAT WAS MISSED</td>
      <td>DETECTOR / CHECK</td>
    </tr>
```

Convert Markdown to HTML in the cells: `&` `<` `>` as entities first, then `` `x` `` as
`<code>x</code>`. The file is one line per row with literal `\n` escapes inside each string.

## 5. Commit and push

One commit: `vreview: rev N - <short summary>`. The gate reads the rev from that subject. Push to
`origin main`. If the gate blocks, its message lists each missing part.

The `S:\Code Review` mirror (`/Volumes/SSData/Code Review/` on the Mac) holds copies of the three
`reference/` files. Whoever syncs it copies them after checking the mirror still matches the
previous commit's version.
