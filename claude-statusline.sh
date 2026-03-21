#!/bin/bash
input=$(cat)
PROFILE=${CLAUDE_PROFILE:-unknown}
case $PROFILE in
  professional) ACCT=Inst;;
  personal) ACCT=Lexi;;
  *) ACCT=$PROFILE;;
esac
echo "$input" | jq -r --arg acct "$ACCT" '$acct + " | " + .model.display_name + " | .../" + (.workspace.project_dir | split("/") | .[-2:] | join("/"))'
