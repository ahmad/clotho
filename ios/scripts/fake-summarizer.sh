#!/bin/sh
# The dev clothod's notification summarizer for tests (CLOTHOD_SUMMARIZER, clothod 0.1.29): never a real model.
# clothod writes the prompt on stdin and shows what this prints. A prompt with "summary-test" in it gets a fixed
# rewrite, after 8 seconds so a test sees the cleaned message first; anything else fails (exit 1), so clothod
# falls back to the message cleaned of Markdown and every other test sees its own text.
input=$(cat)
case $input in
  *summary-test*) sleep 8; echo "The test summarizer says all tests pass." ;;
  *) exit 1 ;;
esac
