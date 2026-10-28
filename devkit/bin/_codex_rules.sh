# shellcheck shell=bash
# The Codex half of `make merge`'s rules (merge_rules.sh header) as one state machine: two
# classifiers and one transition. Pure: no gh, no git, no globals read; merge_rules.sh does the
# reading, the messages and the posts. Sourced by merge_rules.sh; tests/merge_contract.bats holds
# codex_transition to tests/codex_transitions.tsv, every combination.
#
# Inputs (the classifiers' outputs, plus three switches):
#   gap       codex_gap: none (Codex completed a code review of exactly the head), awaiting (no
#             review of the head that Codex can still give: not yet posted, or of an older
#             commit), limit, failed or hung (Codex cannot review: the fallback may stand in)
#   residual  codex_gap: running (a review in progress), open (an unresolved Codex thread), none
#   head      codex_head: the head's codex-review status: none, pending, error, failure, record
#             (a fallback record of the head that Codex's state agrees with), contradicts (one it
#             does not), success (any other success: make merge's own posts, another head's
#             record, claude-kit's legacy "; carried over")
#   fallback  1 when CODEX_FALLBACK=1 (the agent ran the Claude adversarial review), else 0
#   required  1 when GATE_MERGE_REQUIRES names codex-review, else 0
#   plan      GATE_CODEX_REVIEW: 1 (the default) or 0
#   exempt    1 for a bot dependency, docs-only or devkit-sync PR (merge_rules.sh review_exempt);
#             costly to learn, so the caller asks it only where it changes the outcome
#
# The table, first match wins (2026-10-27, generated from origin/main's behaviour by driving
# merge_rules.sh through every combination; the whole table is tests/codex_transitions.tsv):
#   1. codex-review required, the head has no success:
#        none, gap none, residual none          -> post "Codex reviewed <sha7>, 0 open threads"
#        none, exempt                           -> post "Not required (<why>) for <sha7>"
#        none|pending|error, fallback, gap limit|failed|hung
#                                               -> post the fallback record (over pending|error)
#        none|pending|error|failure, otherwise  -> refuse: codex-review=<state>
#   2. gap is not none and plan is 1 (the review is owed):
#        record                                 -> excused by the record
#        none|pending|error|contradicts, fallback, gap limit|failed|hung
#                                               -> post the fallback record, excused
#        contradicts                            -> refuse: the record contradicts Codex
#        exempt                                 -> excused
#        otherwise                              -> not excused
#   3. residual running -> refuse: still running; not excused -> refuse: no review of the head;
#      residual open -> refuse: unresolved findings; else merge.
#   Impossible: a record with gap none or awaiting (fallback_agrees needs a gap Codex cannot
#   close), and any token outside the lists above: refused, naming the combination.

# The CODEX_* globals and $disagreement are outputs, read by merge_rules.sh and the table test:
# shellcheck disable=SC2034

# The blockers that say Codex did not review this head (codex_review.py), which the plan's
# GATE_CODEX_REVIEW=1 refuses unless a fallback record excuses them.
readonly REVIEW_GAPS=$'^(failed|hung|unreviewed|stale)\t'
# The two fallback records (merge_rules.sh header), whole, with the reviewed head last: a head SHA
# anywhere else in the text is no record of it (#207 Codex). "Claude adversarial review (Codex
# <why>) of <sha7>" is fallback_record's; `at limit` was its only <why> until 2026-10-22 and is
# still claude-kit §3c's, so it must match. The other is codex_gate.py --on-limit self-review's.
readonly FALLBACK_RECORD_RES=(
  '^Claude adversarial review \(Codex (at limit|hung [1-9][0-9]* min|failed)\) of ([0-9a-f]{7,40})$'
  '^Codex unavailable \(usage limit\); ([0-9a-f]{7,40}) passed on Claude self-review$'
)

# gap_why <gap kind> <detail>: the <why> of the fallback record a codex_review.py gap calls for;
# exit 1 for a gap Codex can still close itself (a review not yet posted, or stale, with no
# usage-limit note answering it). The one mapping: the hints, the record CODEX_FALLBACK=1 posts
# and fallback_agrees all read it.
gap_why() {
  case $1:$2 in
    hung:*) echo "hung $2 min" ;;
    failed:limit|unreviewed:limit|stale:limit) echo "at limit" ;;
    failed:*) echo failed ;;
    *) return 1 ;;
  esac
}

# observed_whys <blockers>: gap_why of every gap, one per line (none when Codex can still review
# every one).
observed_whys() {
  local kind detail
  while IFS=$'\t' read -r kind _ _ detail; do
    gap_why "$kind" "$detail" || true
  done < <(grep -E "$REVIEW_GAPS" <<<"$1")
}

# fallback_record_of <description> <commit>: 0 when <description> records a fallback review of
# <commit> in one of the two forms; else 1.
fallback_record_of() {
  local re sha
  for re in "${FALLBACK_RECORD_RES[@]}"; do
    [[ "$1" =~ $re ]] || continue
    sha=${BASH_REMATCH[${#BASH_REMATCH[@]} - 1]}
    case "$2" in "$sha"*) return 0 ;; esac
  done
  return 1
}

# fallback_agrees <record> <blockers> <running max>: 0 when the reason the record names is one
# Codex's state shows now: `at limit` and the usage-limit form need a gap the note answers,
# `failed` a failed review, `hung <N> min` a hung one now at least N min old, N not under the
# plan's limit. Else 1, with the contradiction in $disagreement.
fallback_agrees() {
  local claimed whys n m
  whys=$(observed_whys "$2")
  if [[ "$1" =~ ${FALLBACK_RECORD_RES[0]} ]]; then claimed=${BASH_REMATCH[1]}; else claimed="at limit"; fi
  case $claimed in
    "hung "*)
      n=${claimed#hung }; n=${n% min}
      m=$(sed -n 's/^hung \([0-9]*\) min$/\1/p' <<<"$whys" | sort -n | tail -1)
      [ -n "$m" ] && [ "$n" -ge "$3" ] && [ "$n" -le "$m" ] && return 0 ;;
    # A failure at the limit is still a failure: `failed` is true, if less precise.
    failed) grep -qE $'^failed\t' <<<"$2" && return 0 ;;
    *) grep -qxF "$claimed" <<<"$whys" && return 0 ;;
  esac
  [ -z "$whys" ] || whys=$(paste -sd ',' - <<<"$whys" | sed 's/,/, /g')
  disagreement="it says Codex $claimed, but Codex's state is ${whys:-no failure, hang or usage limit}"
  return 1
}

# codex_gap <blockers>: classify codex_review.py's lines (after merge_rules.sh carry_review) into
# $CODEX_GAP and $CODEX_RESIDUAL (header), and $CODEX_WHY, the fallback record's <why> (the first
# gap's), "" where Codex can still review.
codex_gap() {
  CODEX_WHY=$(observed_whys "$1" | head -1)
  if ! grep -qE "$REVIEW_GAPS" <<<"$1"; then
    CODEX_GAP=none
  else
    case $CODEX_WHY in
      "at limit") CODEX_GAP=limit ;;
      "hung "*) CODEX_GAP=hung ;;
      failed) CODEX_GAP=failed ;;
      *) CODEX_GAP=awaiting ;;
    esac
  fi
  # A running review is named before open threads: it may still open more.
  if grep -qE $'^running\t' <<<"$1"; then CODEX_RESIDUAL=running
  elif grep -qE $'^unresolved\t' <<<"$1"; then CODEX_RESIDUAL=open
  else CODEX_RESIDUAL=none
  fi
}

# codex_head <state> <description> <head sha> <blockers> <running max>: classify the head's
# codex-review status into $CODEX_HEAD (header); a contradicting record's reason is in
# $disagreement. A state GitHub does not define reads as failure: never a success.
codex_head() {
  case $1 in
    '') CODEX_HEAD=none ;;
    pending|error) CODEX_HEAD=$1 ;;
    success)
      if ! fallback_record_of "$2" "$3"; then CODEX_HEAD=success
      elif fallback_agrees "$2" "$4" "$5"; then CODEX_HEAD=record
      else CODEX_HEAD=contradicts
      fi ;;
    *) CODEX_HEAD=failure ;;
  esac
}

# codex_transition <gap> <residual> <head> <fallback> <required> <plan> <exempt>: the table
# (header). Sets $CODEX_VERDICT (merge, context, contradicts, running, unreviewed, findings or
# impossible), $CODEX_POST (-, clean, exempt, fallback, or fallback-replacing: over a pending or
# error status) and $CODEX_EXCUSE (what answers an owed review: -, plan, record, fallback, exempt,
# or none when nothing does).
codex_transition() {
  local gap=$1 residual=$2 head=$3 standin=0
  CODEX_VERDICT=merge CODEX_POST=- CODEX_EXCUSE=-
  # Every token in its list, and no record Codex's state could not have agreed with.
  case $gap:$residual:$head:$4$5$6$7 in
    none:*:record:* | awaiting:*:record:*) CODEX_VERDICT=impossible; return ;;
    none:* | awaiting:* | limit:* | failed:* | hung:*) ;;
    *) CODEX_VERDICT=impossible; return ;;
  esac
  case $residual:$head:$4$5$6$7 in
    none:*:[01][01][01][01] | open:*:[01][01][01][01] | running:*:[01][01][01][01]) ;;
    *) CODEX_VERDICT=impossible; return ;;
  esac
  case $head in none|pending|error|failure|record|contradicts|success) ;; *) CODEX_VERDICT=impossible; return ;; esac
  # The fallback record can stand in only where Codex cannot review (gap_why).
  case $4:$gap in 1:limit|1:failed|1:hung) standin=1 ;; esac
  if [ "$5" = 1 ]; then
    case $head:$gap:$residual:$7:$standin in
      none:none:none:*:*) CODEX_POST=clean ;;
      none:*:*:1:*) CODEX_POST=exempt ;;
      none:*:*:*:1) CODEX_POST=fallback ;;
      pending:*:*:*:1 | error:*:*:*:1) CODEX_POST=fallback-replacing ;;
      none:* | pending:* | error:* | failure:*) CODEX_VERDICT=context; return ;;
    esac
  fi
  if [ "$gap" != none ] && [ "$6" = 0 ]; then
    CODEX_EXCUSE=plan
  elif [ "$gap" != none ]; then
    case $head:$standin:$7 in
      record:*) CODEX_EXCUSE=record ;;
      none:1:* | contradicts:1:*) CODEX_EXCUSE=fallback CODEX_POST=fallback ;;
      pending:1:* | error:1:*) CODEX_EXCUSE=fallback CODEX_POST=fallback-replacing ;;
      contradicts:*) CODEX_VERDICT=contradicts; return ;;
      *:1) CODEX_EXCUSE=exempt ;;
      *) CODEX_EXCUSE=none ;;
    esac
  fi
  # A refusal posts nothing: the post is the record of a merge.
  case $residual:$CODEX_EXCUSE in
    running:*) CODEX_VERDICT=running CODEX_POST=- ;;
    *:none) CODEX_VERDICT=unreviewed CODEX_POST=- ;;
    open:*) CODEX_VERDICT=findings CODEX_POST=- ;;
  esac
}
