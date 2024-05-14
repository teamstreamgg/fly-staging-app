#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

REPO_OWNER=$(jq -r .repository.owner.login /github/workflow/event.json)
REPO_NAME=$(jq -r .repository.name /github/workflow/event.json)
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$REPO_OWNER-$REPO_NAME}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  exit 0
fi

# Create the app first if needed.
if ! flyctl status --app "$app"; then
  flyctl launch --dockerfile ./Dockerfile --no-deploy --copy-config --name "$app" --image "$image" --regions "$region" --org "$org"
  # Set secrets before first deploy
  if [ -n "$INPUT_SECRETS" ]; then
    flyctl secrets --app "$app" set $INPUT_SECRETS
  fi
# If it's not first deploy, try updating the secrets
# the command will throw error if there's no change in secret, so ignore non-zero exit code
elif [ -n "$INPUT_SECRETS" ]; then
  flyctl secrets --app "$app" set $INPUT_SECRETS || true
fi

# Deploy the app
if [ "$INPUT_UPDATE" != "false" ]; then
  flyctl deploy --app "$app" --regions "$region" --image "$image" --regions "$region" --strategy immediate --remote-only $INPUT_DEPLOYARGS
fi

# Attach postgres cluster to the app if specified.
if [ -n "$INPUT_POSTGRES" ]; then
  flyctl postgres attach --postgres-app "$INPUT_POSTGRES" || true
fi

# Make some info available to the GitHub workflow.
fly status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "::set-output name=hostname::$hostname"
echo "::set-output name=url::https://$hostname"
echo "::set-output name=id::$appid"
