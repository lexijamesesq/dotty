#!/usr/bin/env bash
# Example script that accidentally embeds an Anthropic API key.
# Pre-pass should detect this and emit a Block verdict.

API_KEY="sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
curl -H "x-api-key: $API_KEY" https://api.anthropic.com/v1/messages
