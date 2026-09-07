#!/usr/bin/env bash
# manifold-config-status.sh — decide whether Manifold Claude configuration is
# present, and say so loudly when it is not.
#
# This fork holds no Actions configuration at all (gcp-gmkx, read at the API
# 2026-09-07: `actions/secrets` total_count 0, `actions/variables` total_count
# 0), so every inference job died at `Validate Manifold Claude configuration`
# with "Missing OLLAMA_API_KEY GitHub secret". Four consecutive scheduled
# Supported Pack Nightly runs failed on that identical signature. A job that is
# always red is read by nobody and is indistinguishable from a job that has gone
# red for a NEW reason, so the red carried no information.
#
# This script is the single source of truth for the question "is the Manifold
# config present?". It DECIDES; it does not ENFORCE — it always exits 0, and the
# workflow gates its Manifold-dependent steps on the `present` output. Keeping
# the decision here rather than in an `if: env.OLLAMA_API_KEY != ''` expression
# buys two things: the six names live in exactly one place, and the loud
# step-summary notice below is possible at all (a step `if:` cannot write one).
#
# `secrets` is deliberately not consulted: GitHub's context-availability table
# does not offer `secrets` to `jobs.<job_id>.steps.<step_id>.if`, and a script
# cannot read it either. The workflows map the secrets and variables into env
# names at job/workflow level, and those env names are what this script reads.
#
# INTERIM (gcp-oz57). This is a MITIGATION, not a fix: it makes an unrunnable
# gate legible, it does not make the gate run. Whether this fork should hold
# Manifold credentials at all is the still-open root question on gcp-gmkx.
#
# Usage: manifold-config-status.sh
#
# Writes two `key=value` lines to stdout, so a workflow step can append them
# straight to $GITHUB_OUTPUT:
#
#     present=true|false
#     missing=<space-separated names of the env vars that resolved empty>
#
# When configuration is absent it also writes a notice to stderr (so it lands in
# the job log) and to $GITHUB_STEP_SUMMARY when that is set (so it is visible
# without opening the log). Always exits 0.

set -euo pipefail

# The six values the `Validate Manifold Claude configuration` step requires to
# be non-empty: two GitHub secrets and four GitHub variables. The two remaining
# checks in that step (ANTHROPIC_BASE_URL, GC_INFERENCE_EXPECTED_MODEL) are
# literals pinned in the workflow env, not repository configuration, so their
# absence is a workflow bug rather than a missing-config condition and they are
# deliberately not listed here.
MANIFOLD_CONFIG_VARS=(
  OLLAMA_API_KEY
  ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_DEFAULT_HAIKU_MODEL
  ANTHROPIC_DEFAULT_SONNET_MODEL
  ANTHROPIC_DEFAULT_OPUS_MODEL
  CLAUDE_CODE_SUBAGENT_MODEL
)

missing=()
for name in "${MANIFOLD_CONFIG_VARS[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    missing+=("$name")
  fi
done

if ((${#missing[@]} == 0)); then
  present=true
else
  present=false
fi

# stdout is the machine-readable half; keep it to these two lines so the caller
# can redirect it into $GITHUB_OUTPUT unfiltered.
printf 'present=%s\n' "$present"
printf 'missing=%s\n' "${missing[*]:-}"

if [[ "$present" == "true" ]]; then
  exit 0
fi

notice="$(
  printf '%s\n' "### Manifold inference gate SKIPPED — configuration absent"
  printf '\n'
  printf '%s\n' "\`Validate Manifold Claude configuration\` and the inference gate did not run."
  printf '%s\n' "This repository resolved no value for:"
  printf '\n'
  for name in "${missing[@]}"; do
    # The backticks are Markdown code spans for the step summary, not command
    # substitution, and the single quotes are what keeps them literal.
    # shellcheck disable=SC2016
    printf -- '- `%s`\n' "$name"
  done
  printf '\n'
  printf '%s\n' "**This job is green because the gate was SKIPPED, not because it passed.**"
  printf '%s\n' "No inference coverage was produced by this run."
  printf '\n'
  printf '%s\n' "Whether this fork should hold Manifold credentials at all is the root"
  printf '%s\n' "question, and it is still OPEN on **gcp-gmkx**. This skip is an explicit"
  printf '%s\n' "INTERIM mitigation (gcp-oz57) that makes an unrunnable gate legible; it is"
  printf '%s\n' "not a fix."
)"

printf '%s\n' "$notice" >&2
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '%s\n' "$notice" >> "$GITHUB_STEP_SUMMARY"
fi

exit 0
