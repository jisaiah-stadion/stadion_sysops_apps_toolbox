#!/usr/bin/env bash
# =============================================================================
# ci/lib/stack-wait.sh
#
# WHAT
#   One function, wait_for_stack, that blocks until a CloudFormation stack
#   reaches a terminal state, and tells the caller WHICH of three things
#   happened:
#
#     0  the stack finished the way we wanted
#     1  the stack finished badly - failed, or rolled back
#     2  we ran out of patience and the stack is STILL WORKING
#
#   This is sourced, not executed. ci/package-and-deploy.sh and ci/destroy.sh
#   both use it.
#
# =============================================================================
# WHY THIS EXISTS INSTEAD OF `aws cloudformation wait`
#
# The AWS CLI's built-in waiters look like the obvious tool and they have two
# problems that both show up as a red pipeline on a healthy deployment.
#
# 1. THEY GIVE UP AT 60 MINUTES, AND SAY SO IN A WAY NOBODY READS.
#
#    `wait stack-create-complete` is botocore's standard waiter: a 30-second
#    delay, 120 attempts. 30 x 120 = 3600 seconds, so it returns non-zero on
#    the dot at one hour whether or not anything is wrong.
#
#    Nothing in Tier 0 ever took that long - the VPC's 33 nested stacks are
#    10-15 minutes - so it never mattered. An Aurora cluster with a reader is
#    15-25 minutes, and a RESTORE from a large snapshot can run well past an
#    hour. The first slow unit turns a working deploy into a failed stage.
#
#    The old code then made it worse: a non-zero waiter was treated as proof
#    the deploy had failed, so it printed "the deploy did not complete" and
#    listed the failed resources - of which there were none, because nothing
#    had failed. A red stage, an empty failure report, and a database quietly
#    finishing its creation a few minutes later.
#
# 2. THE `||` FALLBACK PATTERN HANGS FOR AN EXTRA HOUR.
#
#    The approval path used to do this:
#
#        wait stack-update-complete || wait stack-create-complete
#
#    The intent was "I do not know if this is a create or an update, try
#    both." What actually happens is governed by each waiter's ACCEPTORS - the
#    list of statuses it recognises - and stack-create-complete recognises
#    only the create-path ones: CREATE_COMPLETE, CREATE_FAILED,
#    DELETE_COMPLETE, DELETE_FAILED, ROLLBACK_FAILED, ROLLBACK_COMPLETE.
#
#    UPDATE_ROLLBACK_COMPLETE is not in that list. Neither is UPDATE_COMPLETE.
#    A status a waiter does not recognise is not an answer - it just keeps
#    polling. So a failed update finished the first waiter in minutes and then
#    sat in the second one for a further 60 minutes before failing, and a
#    SUCCESSFUL update that took over an hour timed out the first waiter and
#    then burned another hour in the second before reporting failure.
#
#    That was on the infra-promote path - the one with the approval gates, the
#    one that reaches production.
#
# So: poll describe-stacks ourselves, decide from the status string, and keep
# "timed out" as its own outcome rather than folding it into "failed".
#
# =============================================================================
# HOW LONG TO WAIT, AND THE ONE THING THAT MUST STAY TRUE
#
# STACK_WAIT_MINUTES is the budget. Override it per stage if a unit genuinely
# needs longer:
#
#     STACK_WAIT_MINUTES=240 bash ci/package-and-deploy.sh <config> --execute
#
# THE CODEBUILD TIMEOUT MUST BE LARGER THAN THIS BUDGET, with room to spare
# for the lint and package steps that run first. If CodeBuild kills the build
# before the wait finishes, none of the reporting below ever runs and the log
# just stops - which is the failure mode this file exists to remove.
#
#     pipelines/*.yaml  BuildTimeoutMinutes  150   <- must be the larger one
#     here              STACK_WAIT_MINUTES   120
#
# Change one and look at the other. There is no way to read CodeBuild's own
# timeout from inside the build, so this pairing cannot be checked at runtime.
# =============================================================================

# The budget, and how often we look. 20 seconds for a two-hour budget is 360
# DescribeStacks calls - nowhere near a rate limit, and tight enough that the
# log reports a failure promptly rather than up to a minute later.
STACK_WAIT_MINUTES="${STACK_WAIT_MINUTES:-120}"
STACK_WAIT_INTERVAL="${STACK_WAIT_INTERVAL:-20}"

# Set by wait_for_stack to the last status it saw, so the caller can name it in
# an error message without asking AWS again.
STACK_WAIT_FINAL_STATUS=""

# A link straight to the stack's Events tab, which is where you go for both a
# failure and a deploy that is still running.
stack_console_url() {
  printf 'https://%s.console.aws.amazon.com/cloudformation/home?region=%s#/stacks/events?stackId=%s' \
    "$REGION" "$REGION" "$1"
}

# One DescribeStacks call, reduced to a single word.
#
# A stack that is not there is a legitimate answer, not an error - it is what
# success looks like when you are waiting for a deletion - so it comes back as
# STACK_NOT_FOUND rather than a non-zero exit. Anything else that goes wrong
# (expired credentials, throttling) exits non-zero and lets the caller decide
# whether to retry.
#
# stderr is folded into the captured output on purpose: the "does not exist"
# wording only appears there.
_stack_status() {
  local stack="$1" out
  if out="$(aws "${TGT_ARGS[@]}" cloudformation describe-stacks \
              --region "$REGION" --stack-name "$stack" \
              --query 'Stacks[0].StackStatus' --output text </dev/null 2>&1)"; then
    printf '%s' "$out"
    return 0
  fi
  case "$out" in
    *"does not exist"*|*"Stack with id"*" not found"*)
      printf 'STACK_NOT_FOUND'
      return 0
      ;;
  esac
  printf '%s' "$out" >&2
  return 1
}

# wait_for_stack <mode> <stack-name>
#
#   mode  settle  waiting for a create or an update to land
#         delete  waiting for a deletion
#
# Uses the REGION and TGT_ARGS the calling script has already set up.
#
# Returns 0 on the outcome asked for, 1 on a terminal state that is not it,
# 2 when the budget ran out while the stack was still in progress.
wait_for_stack() {
  local mode="$1" stack="$2"
  local max_polls=$(( STACK_WAIT_MINUTES * 60 / STACK_WAIT_INTERVAL ))
  local poll=0 consecutive_errors=0 status=""

  # Heartbeat roughly every two minutes. A silent hour of log is
  # indistinguishable from a hung build.
  local heartbeat_every=$(( 120 / STACK_WAIT_INTERVAL ))
  [ "$heartbeat_every" -lt 1 ] && heartbeat_every=1

  while [ "$poll" -lt "$max_polls" ]; do
    if ! status="$(_stack_status "$stack")"; then
      # Transient failures happen - a throttle, a blip. Five in a row is not
      # transient, and continuing to poll would just burn the whole budget
      # against an error we already know about.
      consecutive_errors=$(( consecutive_errors + 1 ))
      if [ "$consecutive_errors" -ge 5 ]; then
        echo >&2
        echo "ERROR: could not read the status of ${stack} five times running." >&2
        echo "  The error above is the last one. Credentials expiring mid-deploy" >&2
        echo "  is the usual cause - see the note about profiles in" >&2
        echo "  ci/package-and-deploy.sh." >&2
        echo "  THE DEPLOY ITSELF MAY STILL BE RUNNING: $(stack_console_url "$stack")" >&2
        STACK_WAIT_FINAL_STATUS="UNKNOWN"
        return 1
      fi
      sleep "$STACK_WAIT_INTERVAL"
      poll=$(( poll + 1 ))
      continue
    fi
    consecutive_errors=0
    STACK_WAIT_FINAL_STATUS="$status"

    # The outcome we were asked for.
    case "${mode}:${status}" in
      # A deleted stack stops existing, so both of these are success. Which
      # one you get is a race with CloudFormation's own bookkeeping.
      delete:DELETE_COMPLETE|delete:STACK_NOT_FOUND) return 0 ;;
      settle:CREATE_COMPLETE|settle:UPDATE_COMPLETE|settle:IMPORT_COMPLETE) return 0 ;;
    esac

    case "$status" in
      # Everything CloudFormation does ends in _IN_PROGRESS while it is doing
      # it, which is what makes this safe to match on rather than listing
      # every status. UPDATE_COMPLETE_CLEANUP_IN_PROGRESS is included and
      # should be: the stack is nearly done and becomes UPDATE_COMPLETE
      # shortly, so waiting is correct.
      *_IN_PROGRESS)
        if [ $(( poll % heartbeat_every )) -eq 0 ]; then
          printf '  %s  %s  (%dm elapsed, giving up at %dm)\n' \
            "$stack" "$status" \
            $(( poll * STACK_WAIT_INTERVAL / 60 )) "$STACK_WAIT_MINUTES"
        fi
        sleep "$STACK_WAIT_INTERVAL"
        poll=$(( poll + 1 ))
        ;;

      # Terminal, and not what we asked for. This is the branch the old code
      # could not reach on the approval path, because a status its waiter did
      # not recognise left it polling instead of reporting.
      *)
        return 1
        ;;
    esac
  done

  # Still in progress when the budget ran out. NOT a failure - the caller has
  # to say something different here, because the stack is still working and
  # will probably succeed.
  return 2
}
