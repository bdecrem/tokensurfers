# Token Surfers

Vibe code while you surf. You tell **Splat**, an inflatable tube man who is also a coding agent, what app you want. He builds it as one self-contained `index.html` while you play **Token Surfers**, a Subway-Surfers-style runner, in the bottom half of the screen. The agent's work shows up in the game:

- streamed tokens become coin trails;
- each tool call is a train with the tool's name on the front;
- bugs that the test run finds crawl onto the track;
- a finished build rains confetti.

Splat says what he's doing out loud. You can type or hold the mic to talk back while he works. Your note reaches him at his next step, the way Claude Code handles messages you queue during a turn.

iPhone and Mac (Catalyst), SwiftUI, no dependencies. The web side is a small Next.js app: the agent's LLM route, accounts, a gallery of published creations, and the leaderboard.

> This repo is a snapshot. The code is developed in [bdecrem/hilma](https://github.com/bdecrem/hilma) and released here periodically, one commit per snapshot naming the hilma commit it came from. MIT licensed — see [LICENSE](LICENSE).

## Layout

```
ios/      the app (XcodeGen: project.yml is the source of truth)
web/      Next.js: /surf pages + /api/surf/* routes
schema/   Supabase SQL (scores, accounts, published apps, upvotes)
art/      Splat's source SVGs (front, back, back-smooth, rigged back)
```

## How the agent works

- **The loop runs on the phone** (`ios/TokenSurfers/Agent/Studio.swift`). Each Messages call is streamed. Every `tool_use` runs in order, and all the results go back in one user message. The loop repeats until `end_turn`.
- **The tools** are `write_file`, `edit_file`, `read_file` and `run_app`. `run_app` loads the page in a hidden web view and returns errors plus a screenshot.
- **Captions come first.** Every tool input starts with a `caption` field, which the app reads out of the half-streamed JSON and speaks.
- **The server owns the model, the prompt and the tools** (`web/src/app/api/surf/llm/route.ts`, `web/src/lib/surf/prompt.ts`). The phone sends only `messages`. The model is pinned to Claude Opus 5.5 with effort capped at medium.
- **Mid-build notes** wait in a queue. When the current step ends, they're added to the next user message as `[user, mid-build]: …` text blocks, next to the tool results. "⚡ now" cancels the half-streamed turn and delivers them straight away.

## Run it

**Web**

```bash
cd web
cp .env.example .env.local    # fill it in
pnpm install
pnpm dev                      # http://localhost:3000/surf
```

Apply `schema/*.sql` to a Supabase project first. The Anthropic key and the Supabase service key live only on the server.

**App**

```bash
cd ios
cp TokenSurfers/App/Secrets.swift.example TokenSurfers/App/Secrets.swift
# set backendURL to your web deployment and appKey to its SURF_APP_KEY
xcodegen generate
xcodebuild -project TokenSurfers.xcodeproj -scheme TokenSurfers \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

`SURF_APP_KEY` gates the app's calls to your server. It ships inside the app binary, so treat it as a way to recognize the app, not as a password. Anyone who extracts it can use the agent route, so budget and rate-limit that route on your side.
